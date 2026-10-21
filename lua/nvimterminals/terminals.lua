local config = require("nvimterminals.config")
local agent = require("nvimterminals.agent")

local M = {}

-- name -> {
--   buf, job_id, pid,            runtime state
--   dead, exit_code,             kept after on_exit until the buffer is deleted
--   agent_enabled, policy,       added in agent layer (see agent docs)
-- }
M.terminals = {}
M.current = nil

local augroup = vim.api.nvim_create_augroup("nvimterminals", { clear = true })

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function tab_wins(tabpage)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_tabpage(win) == tabpage
  end, vim.api.nvim_list_wins())
end

local function anchor_win()
  local cur = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(cur)].buftype ~= "terminal" then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= cur and vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "terminal" then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end

-- find a non-floating window displaying one of our terminals.
-- searches all tabpages (current tab preferred, then fallback) so a terminal
-- visible in another tab is reused instead of getting a second window.
-- NOTE: the picker/toggle semantics are still single-pane across the whole UI;
-- per-tab terminal panes are intentionally not supported.
function M.find_open_win()
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local fallback
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not is_float(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      for _, state in pairs(M.terminals) do
        if state.buf == buf then
          local tab = vim.api.nvim_win_get_tabpage(win)
          if tab == cur_tab then
            return win
          end
          fallback = fallback or win
        end
      end
    end
  end
  return fallback
end

-- display a terminal buffer: reuse the open term pane if there is one
-- (possibly in another tab), otherwise open a new split anchored to an
-- editor window
local function show_buffer(bufnr)
  local existing = M.find_open_win()
  if existing and vim.api.nvim_win_is_valid(existing) then
    local tab = vim.api.nvim_win_get_tabpage(existing)
    if tab ~= vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_tabpage(tab)
    end
    vim.api.nvim_win_set_buf(existing, bufnr)
    vim.api.nvim_set_current_win(existing)
    return
  end
  anchor_win()
  local position = config.get("position")
  local size = config.get("size")
  local cmds = {
    right = string.format("rightbelow %dvsplit", math.floor(vim.o.columns * size)),
    left = string.format("leftabove %dvsplit", math.floor(vim.o.columns * size)),
    top = string.format("leftabove %dsplit", math.floor(vim.o.lines * size)),
    bottom = string.format("rightbelow %dsplit", math.floor(vim.o.lines * size)),
  }
  vim.cmd(cmds[position] or cmds.right)
  vim.api.nvim_win_set_buf(0, bufnr)
end

local function job_running(state)
  if state == nil or state.dead then
    return false
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end
  local ok, res = pcall(vim.fn.jobwait, { state.job_id }, 0)
  return ok and type(res) == "table" and res[1] == -1
end

-- Resolve name/state by JOB ID. Used by on_exit so a renamed terminal
-- records its exit under its CURRENT name (the old captured-name closure
-- stranded updates under the stale key -- R1 KNOWN-ISSUE, flipped here).
-- Equivalent to the old guard for every non-renamed flow: job ids are unique
-- per process, so a late event from a replaced job simply finds no match.
local function state_by_job(job)
  for name, state in pairs(M.terminals) do
    if state.job_id == job then
      return name, state
    end
  end
end

local function on_exit_cb()
  return function(job, code, event)
    local name, state = state_by_job(job)
    if not state or state.closing then
      -- closing: M.close() already committed to teardown; staying silent
      -- matches the forced-delete baseline (:bd fires no NvimterminalsExit)
      return
    end
    state.dead = true
    state.exit_code = code
    state.exit_event = event
    vim.api.nvim_exec_autocmds("User", {
      pattern = "NvimterminalsExit",
      data = {
        name = name,
        buf = state.buf,
        job_id = job,
        pid = state.pid,
        exit_code = code,
        event = event,
      },
    })
  end
end

-- state lives until the terminal BUFFER dies; job exit only marks it dead.
-- NOTE: nvim_buf_delete() on a hidden buffer fires BufUnload+BufWipeout, NOT
-- BufDelete — listen to both so ":bd" and programmatic deletes behave alike.
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = augroup,
  desc = "nvimterminals: drop terminal state when its buffer is deleted",
  callback = function(ev)
    local bufnr = tonumber(ev.buf)
    for name, state in pairs(M.terminals) do
      if state.buf == bufnr then
        if state.job_id and not state.dead then
          pcall(vim.fn.jobstop, state.job_id)
        end
        M.terminals[name] = nil
        if M.current == name then
          M.current = nil
        end
        break
      end
    end
    for _, state in pairs(M.terminals) do
      if state.policy == bufnr then
        state.policy = nil
      end
    end
  end,
})

-- :w on a policy buffer is a SAVE GESTURE, not a file write: the buffer
-- content IS the live policy (read fresh every send), so the acwrite buftype
-- routes writes here and we only clear the modified flag. No file is ever
-- written (the old empty-buftype buffers tried to create junk files named
-- "nvimterminals://policy/<name>" and errored E212).
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = augroup,
  pattern = "nvimterminals://policy/*",
  callback = function(ev)
    vim.bo[ev.buf].modified = false
  end,
  desc = "nvimterminals: policy :w is a no-op save (the buffer IS the live policy)",
})

-- Observability: report named terminals still running when nvim exits.
-- Uses nvim_echo (err=false, no history) rather than vim.notify so headless
-- test output can't pick up a trailing line and break `tail -1` checks.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = augroup,
  desc = "nvimterminals: echo still-running terminals at exit",
  callback = function()
    local running = {}
    for name, state in pairs(M.terminals) do
      if job_running(state) then
        table.insert(running, name)
      end
    end
    if #running > 0 and #vim.api.nvim_list_uis() > 0 then
      table.sort(running)
      vim.api.nvim_echo({ { "nvimterminals: still running at exit: " .. table.concat(running, ", ") } }, false, {})
    end
  end,
})

function M.toggle(name)
  if name == "" then
    name = nil
  end
  name = name or M.current or "main"
  local state = M.terminals[name]

  if job_running(state) then
    local visible = {}
    for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
      if vim.api.nvim_win_is_valid(win) and not is_float(win) then
        table.insert(visible, win)
      end
    end
    if #visible > 0 then
      -- visible -> hide; job keeps running
      for _, win in ipairs(visible) do
        local tab = vim.api.nvim_win_get_tabpage(win)
        if #tab_wins(tab) > 1 then
          vim.api.nvim_win_close(win, false)
        else
          vim.notify("nvimterminals: terminal is the only window in this tab", vim.log.levels.WARN)
        end
      end
      M.current = name
      return
    end
    show_buffer(state.buf)
    M.current = name
    return
  end

  -- spawn fresh. A previous (dead) terminal is cleaned up first: its buffer is
  -- deleted so it doesn't leak, and if it occupied a pane we replace that pane
  -- in place (no new split) so we keep the single-pane guarantee.
  local prev = state
  local old_buf = prev and prev.buf and vim.api.nvim_buf_is_valid(prev.buf) and prev.buf or nil

  local bufnr = vim.api.nvim_create_buf(false, false)
  M.terminals[name] = nil

  local reused_win
  if old_buf then
    for _, win in ipairs(vim.fn.win_findbuf(old_buf)) do
      if vim.api.nvim_win_is_valid(win) and not is_float(win) then
        reused_win = win
        break
      end
    end
  end

  if reused_win then
    local tab = vim.api.nvim_win_get_tabpage(reused_win)
    if tab ~= vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_tabpage(tab)
    end
    vim.api.nvim_win_set_buf(reused_win, bufnr)
    vim.api.nvim_set_current_win(reused_win)
    if old_buf then
      pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
    end
  else
    if old_buf then
      pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
    end
    show_buffer(bufnr)
  end

  local cmd = config.get("terminal_cmd")
  local on_exit = on_exit_cb()
  local job_id
  if vim.fn.has("nvim-0.11") == 1 then
    job_id = vim.fn.jobstart(cmd, { term = true, on_exit = on_exit })
  else
    job_id = vim.fn.termopen(cmd, { on_exit = on_exit })
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, "term://" .. name)
  local pid
  local ok_pid, res_pid = pcall(vim.fn.jobpid, job_id)
  if ok_pid then
    pid = res_pid
  end

  M.terminals[name] = {
    buf = bufnr,
    job_id = job_id,
    pid = pid,
    dead = false,
    exit_code = nil,
    agent_enabled = prev and prev.agent_enabled or false,
    policy = prev and prev.policy or nil,
  }
  M.current = name
end

function M.list()
  local names = {}
  for name, state in pairs(M.terminals) do
    if vim.api.nvim_buf_is_valid(state.buf) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

function M.select()
  local names = M.list()
  if #names == 0 then
    M.toggle()
    return
  end
  vim.ui.select(names, {
    prompt = "Select terminal: ",
    format_item = function(name)
      local state = M.terminals[name]
      if not state or not state.buf then
        return name
      end
      local visible = #vim.fn.win_findbuf(state.buf) > 0
      local tag = state.dead and "[dead]   " or (visible and "[open]   " or "[hidden]")
      local marker = state.agent_enabled and " [agent]" or ""
      return string.format("%s %s%s", tag, name, marker)
    end,
  }, function(choice)
    if choice then
      M.toggle(choice)
    end
  end)
end

function M.get_current()
  return M.current
end

-- Live runtime state for a terminal, or nil when unknown. Returns the actual
-- state table (same object as M.terminals[name]); treat it as read-only.
function M.get(name)
  return M.terminals[name]
end

local function bufnr_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

-- nvim 0.12.5 quirk (repro without this plugin): renaming a buffer that
-- carries a custom term://-style name leaves a GHOST buffer that re-takes the
-- vacated name (empty, unlisted, unmodified). Evict it so the old name is
-- immediately reusable (round-trip renames). Guarded: never touches a
-- terminal buffer or a referenced policy buffer.
local function drop_ghost(bname)
  local g = bufnr_by_name(bname)
  if g ~= -1 and vim.bo[g].buftype == "" then
    for _, st in pairs(M.terminals) do
      if st.buf == g or st.policy == g then
        return
      end
    end
    pcall(vim.api.nvim_buf_delete, g, { force = true })
  end
end

-- Rename a terminal in place (R2). Atomic: every pre-check runs before any
-- mutation; a mid-rename buffer-name failure rolls the whole operation back.
-- The state table keeps its IDENTITY (only the key moves), so nvimcp callers
-- holding an M.get result keep working. M.current follows; term://<bufname>
-- and the policy buffer (by reference or by orphan scan of the OLD name)
-- follow too. Returns (true, new) or (false, reason).
function M.rename(name, new)
  name = name or M.current or "main"
  local state = M.terminals[name]
  if not state then
    return false, "no_such_terminal"
  end
  new = tostring(new or "")
  if new == "" or new:find("[\n\r]") then
    return false, "invalid_name"
  end
  if new == name then
    return false, "same_name"
  end
  if M.terminals[new] then
    return false, "terminal_exists"
  end
  if bufnr_by_name("term://" .. new) ~= -1 then
    return false, "buffer_name_exists"
  end
  if bufnr_by_name("nvimterminals://policy/" .. new) ~= -1 then
    return false, "policy_name_exists"
  end

  local polbuf = state.policy
  if not (polbuf and vim.api.nvim_buf_is_valid(polbuf)) then
    local found = bufnr_by_name("nvimterminals://policy/" .. name)
    polbuf = found ~= -1 and found or nil
  end

  M.terminals[name] = nil
  M.terminals[new] = state
  if M.current == name then
    M.current = new
  end

  local ok, err = pcall(vim.api.nvim_buf_set_name, state.buf, "term://" .. new)
  if not ok then
    M.terminals[new] = nil
    M.terminals[name] = state
    if M.current == new then
      M.current = name
    end
    return false, "buffer_name_exists: " .. tostring(err)
  end
  drop_ghost("term://" .. name)
  if polbuf then
    local ok_pol, err_pol = pcall(vim.api.nvim_buf_set_name, polbuf, "nvimterminals://policy/" .. new)
    if not ok_pol then
      pcall(vim.api.nvim_buf_set_name, state.buf, "term://" .. name)
      drop_ghost("term://" .. new)
      M.terminals[new] = nil
      M.terminals[name] = state
      if M.current == new then
        M.current = name
      end
      return false, "buffer_name_exists: " .. tostring(err_pol)
    end
    drop_ghost("nvimterminals://policy/" .. name)
  end
  return true, new
end

-- Pane successor for close(): alphabetically-first LIVE terminal, falling
-- back to the first dead one (dead buffers survive for scrollback). M.list()
-- is sorted and valid-buffer-only.
local function successor_name(exclude)
  local dead_fallback
  for _, n in ipairs(M.list()) do
    if n ~= exclude then
      if job_running(M.terminals[n]) then
        return n
      end
      dead_fallback = dead_fallback or n
    end
  end
  return dead_fallback
end

-- Close a terminal (R3). When it holds the pane: a successor is swapped in
-- (window survives ON A TERMINAL -- deliberate delta vs raw nvim, which kills
-- the pane window, pinned in R1 section 1); the LAST visible terminal's pane
-- window closes when the tab has >1 window (toggle-hide rule), else nvim's
-- own buffer replacement handles the sole window. Focus and tabpage are never
-- moved by the swap path. Then jobstop + bounded settle BEFORE the forced
-- buffer delete: nvim 0.12.5 deadlocks a later vim.wait when a terminal
-- buffer with in-flight pty output is force-deleted (R1 finding), and raw
-- :bd does not protect against this -- another deliberate delta. The buffer
-- delete stays the ONLY state-drop path (BufDelete/BufWipeout autocmd). The
-- policy buffer SURVIVES so a re-spawn re-attaches it by name (existing
-- documented semantics). Returns (true, name) or (false, reason).
function M.close(name)
  name = name or M.current or "main"
  local state = M.terminals[name]
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false, "no_such_terminal"
  end

  local pane
  for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
    if not is_float(win) then
      pane = win
      break
    end
  end
  if pane then
    local succ = successor_name(name)
    if succ then
      vim.api.nvim_win_set_buf(pane, M.terminals[succ].buf)
    else
      local tab = vim.api.nvim_win_get_tabpage(pane)
      if #tab_wins(tab) > 1 then
        pcall(vim.api.nvim_win_close, pane, false)
      end
    end
  end

  if state.job_id and not state.dead then
    state.closing = true
    pcall(vim.fn.jobstop, state.job_id)
    -- bounded settle: let the job die + pty flush BEFORE the forced delete
    -- (nvim 0.12.5 wait-deadlock, R1 finding). The closing flag keeps the
    -- exit callback silent so close() matches the forced-delete baseline.
    vim.wait(500, function()
      local okw, resw = pcall(vim.fn.jobwait, { state.job_id }, 0)
      return (not okw) or type(resw) ~= "table" or resw[1] ~= -1
    end, 25)
  end

  pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  return true, name
end

-- ---------------------------------------------------------------------------
-- Agent control layer: the implementation lives in nvimterminals.agent_api
-- (C3 extraction). The bindings below are the frozen entry surface nvimcp
-- compiles against (see NOTES cross-repo contract) — EXTEND-only there.
-- M.get above is part of that surface and stays in terminals.lua.
-- ---------------------------------------------------------------------------
local agent_api = require("nvimterminals.agent_api")
agent_api.bind(M, job_running)

M.policy_buffer = agent_api.policy_buffer
M.agent_toggle = agent_api.agent_toggle
M.agent_enabled = agent_api.agent_enabled
M.send = agent_api.send
M.lines = agent_api.lines

return M
