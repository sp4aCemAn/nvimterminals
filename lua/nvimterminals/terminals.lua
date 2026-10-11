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

local function on_exit_cb(name)
  return function(job, code, event)
    local state = M.terminals[name]
    if not state or state.job_id ~= job then
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
  local on_exit = on_exit_cb(name)
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

-- ---------------------------------------------------------------------------
-- Agent control layer
-- Effective send policy for terminal `t`:
--   global config.agent.enabled AND t.agent_enabled AND policy allows command
-- policy = t.policy buffer (if it exists) else config.agent.allow.
-- ---------------------------------------------------------------------------

local function policy_bufname(name)
  return "nvimterminals://policy/" .. name
end

local function bufnr_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return -1
end

-- resolve the raw pattern lines for a terminal, or nil to fall back to global
local function policy_lines(name, state)
  local buf = state and state.policy
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    local found = bufnr_by_name(policy_bufname(name))
    if found ~= -1 and vim.api.nvim_buf_is_valid(found) then
      buf = found
      if state then
        state.policy = buf
      end
    else
      return nil
    end
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function to_command_lines(s)
  local res = {}
  s = (s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for seg in (s .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = seg:match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:find("^#") then
      table.insert(res, trimmed)
    end
  end
  return res
end

-- Open (or reuse) the per-terminal policy scratch buffer.
-- Returns bufname, bufnr (bufnr may be nil when create=false and none exist).
function M.policy_buffer(name, create)
  name = name or M.current or "main"
  local state = M.terminals[name]
  local bufname = policy_bufname(name)

  local buf = state and state.policy
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    local found = bufnr_by_name(bufname)
    buf = (found ~= -1 and vim.api.nvim_buf_is_valid(found)) and found or nil
  end

  if not buf and create then
    buf = vim.api.nvim_create_buf(false, false)
    pcall(vim.api.nvim_buf_set_name, buf, bufname)
    vim.bo[buf].buflisted = false
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "lua"
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {
      "# nvimterminals policy for terminal: " .. name,
      "# one Lua pattern per line; matched against the trimmed command.",
      "# 'deny <pattern>' denies before allows; a lone '*' allows everything.",
      "# empty / comment-only policy denies all commands.",
    })
  end

  if buf and state then
    state.policy = buf
  end
  return bufname, buf
end

-- toggle per-terminal agent control. Returns (enabled, name) or (nil, reason)
function M.agent_toggle(name)
  name = name or M.current or "main"
  local state = M.terminals[name]
  if not state then
    return nil, name
  end
  state.agent_enabled = not state.agent_enabled
  return state.agent_enabled, name
end

function M.agent_enabled(name)
  local state = M.terminals[name]
  return state and state.agent_enabled or false
end

-- Observation for send() settling: whole-buffer snapshot. Fresh screens
-- paint at the TOP (the cursor starts at row 1), so tail-only checks never
-- fire even though output landed. Line count + concatenated compare.
local function buffer_signature(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, total, false), "\n")
  return total, body
end

-- Send `data` (raw bytes/keystrokes) to a terminal's pty, gated by the
-- effective agent policy. Always returns a table; never raises.
--   opts.lstrip      left-strip each outgoing line (indentation)
--   opts.wait_ms     after a successful send, wait up to this many ms for
--                    output to commit to the terminal buffer (yields into
--                    nvim's event loop while waiting; 0 = don't wait).
--                    Result gains settled=true|false.
function M.send(name, data, opts)
  opts = opts or {}
  data = tostring(data or "")
  name = name or M.current
  local state = name and M.terminals[name]
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) or state.dead then
    return { ok = false, reason = "no_such_terminal", detail = tostring(name) }
  end
  if not job_running(state) then
    return { ok = false, reason = "no_such_terminal", detail = tostring(name) .. " is not running" }
  end

  local g = config.get("agent") or {}
  if g.enabled ~= true then
    return { ok = false, reason = "agent_disabled", detail = "global agent.enabled is false" }
  end
  if not state.agent_enabled then
    return { ok = false, reason = "agent_disabled", detail = name .. ".agent_enabled is false" }
  end

  local pol = agent.parse(policy_lines(name, state) or g.allow or {})
  for _, line in ipairs(to_command_lines(data)) do
    local allowed, detail = agent.check(line, pol)
    if not allowed then
      return { ok = false, reason = "policy_denied", detail = detail }
    end
  end

  local payload = data
  if opts.lstrip then
    payload = payload:gsub("^%s+", ""):gsub("([\r\n])[ \t]+", "%1")
  end

  local ok, err = pcall(vim.api.nvim_chan_send, state.job_id, payload)
  if not ok then
    return { ok = false, reason = "no_such_terminal", detail = "chan_send failed: " .. tostring(err) }
  end
  local res = { ok = true }
  local wait_ms = tonumber(opts.wait_ms) or 0
  if wait_ms > 0 and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local s0c, s0b = buffer_signature(state.buf)
    local changed = vim.wait(wait_ms, function()
      local s1c, s1b = buffer_signature(state.buf)
      return s1c ~= s0c or s1b ~= s0b
    end, 50)
    vim.wait(50) -- small tail so streamed multi-line output commits
    res.settled = changed == 1 or changed == true
  else
    res.settled = nil -- plugin honors wait only when requested
  end
  return res
end

-- Read the terminal's scrollback (read-only, NOT gated by policy).
-- opts.n      last n lines (default 200); opts.start/opts.count for a range
function M.lines(name, opts)
  opts = opts or {}
  name = name or M.current
  local state = name and M.terminals[name]
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return { ok = false, reason = "no_such_terminal", detail = tostring(name) }
  end
  local buf = state.buf
  local total = vim.api.nvim_buf_line_count(buf)
  local n = math.max(0, opts.n or 200)

  local first, last
  if opts.start then
    first = opts.start
    last = first + (opts.count or n) - 1
  else
    last = total
    first = math.max(1, total - n + 1)
  end
  first = math.max(1, math.min(first, total + 1))
  last = math.max(0, math.min(last, total))

  local out = {}
  if last >= first then
    local raw = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    for i, text in ipairs(raw) do
      table.insert(out, { lnum = first + i - 1, text = text })
    end
  end
  return {
    ok = true,
    name = name,
    buf = buf,
    total = total,
    start = first,
    ["end"] = last,
    lines = out,
    dead = state.dead or false,
    running = job_running(state),
    pid = state.pid,
    exit_code = state.exit_code,
  }
end

return M
