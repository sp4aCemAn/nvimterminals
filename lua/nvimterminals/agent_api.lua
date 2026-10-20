-- Agent control layer, extracted verbatim from terminals.lua (C3).
-- Effective send policy for terminal `t`:
--   global config.agent.enabled AND t.agent_enabled AND policy allows command
-- policy = t.policy buffer (if it exists) else config.agent.allow.
--
-- The live terminals module (terminals.lua) and its job_running helper are
-- injected via bind() so this module reads state without owning it; nvimcp
-- compiles against the facade re-exported by terminals.lua (send/lines/
-- policy_buffer/agent_toggle/agent_enabled) — EXTEND-only there.

local config = require("nvimterminals.config")
local agent = require("nvimterminals.agent")

local M = {}

local T
local job_running

function M.bind(terminals_module, is_running)
  T = terminals_module
  job_running = is_running
end

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
  name = name or T.current or "main"
  local state = T.terminals[name]
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
  name = name or T.current or "main"
  local state = T.terminals[name]
  if not state then
    return nil, name
  end
  state.agent_enabled = not state.agent_enabled
  return state.agent_enabled, name
end

function M.agent_enabled(name)
  local state = T.terminals[name]
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
  name = name or T.current
  local state = name and T.terminals[name]
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
  name = name or T.current
  local state = name and T.terminals[name]
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
