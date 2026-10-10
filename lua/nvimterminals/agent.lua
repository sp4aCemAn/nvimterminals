-- Whitelist semantics for agent-driven sends.
-- A policy is a list of lines: one Lua pattern per line, matched against the
-- trimmed input with string.find(line, pattern, 1, false).
--   "#" ...          comment / blank line -> ignored
--   "*"              allow anything into this terminal
--   "deny <pattern>" explicit deny, evaluated before allows
-- An empty policy denies everything.

local M = {}

function M.parse(lines)
  local pol = { allow = {}, deny = {}, wildcard = false }
  for _, raw in ipairs(lines or {}) do
    local line = vim.trim(raw or "")
    if #line > 0 and not line:find("^#") then
      local deny_pat = line:match("^deny%s+(.+)$")
      if deny_pat then
        table.insert(pol.deny, vim.trim(deny_pat))
      elseif line == "*" then
        pol.wildcard = true
      else
        table.insert(pol.allow, line)
      end
    end
  end
  return pol
end

-- returns allowed (bool), detail (string|nil)
-- detail is "pattern: <p>" for explicit denies, "<line>" for no-match
function M.check(line, pol)
  for _, d in ipairs(pol.deny) do
    if line:find(d, 1, false) then
      return false, "pattern: " .. d
    end
  end
  if pol.wildcard then
    return true
  end
  for _, a in ipairs(pol.allow) do
    if line:find(a, 1, false) then
      return true
    end
  end
  return false, line
end

return M
