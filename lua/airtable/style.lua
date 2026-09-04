-- Classifies a buffer.fields key into a rendering style by name pattern. Never fails
-- the render — an unrecognized key falls back to 'plain'.

local M = {}

---@alias AirtableSectionStyle 'pill'|'heading'|'plain'

local PILL_PATTERNS = {
  'status', 'assignee', 'reviewer', 'type', 'priority', 'label', 'squad', 'application',
}
local HEADING_PATTERNS = {
  'name', 'title', 'id',
}

local function matches_any(key, patterns)
  local lower = key:lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) then return true end
  end
  return false
end

---@param key any
---@return AirtableSectionStyle
function M.classify(key)
  local ok, result = pcall(function()
    if type(key) ~= 'string' then return 'plain' end
    if matches_any(key, PILL_PATTERNS) then return 'pill' end
    if matches_any(key, HEADING_PATTERNS) then return 'heading' end
    return 'plain'
  end)
  if ok then return result end
  return 'plain'
end

return M
