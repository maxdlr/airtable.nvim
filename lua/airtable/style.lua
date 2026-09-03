-- Classifies a `buffer.fields` key (e.g. "assignee", "status") into a rendering style,
-- based on common naming patterns. This only affects *default* styling — it never fails
-- the render; an unrecognized key always falls back to 'plain'.

local M = {}

---@alias AirtableSectionStyle 'pill'|'heading'|'plain'

-- Patterns are matched case-insensitively against the *whole* key. Order doesn't matter
-- since each list is checked independently and pill/heading are mutually exclusive by
-- construction (a key can't plausibly match both).
local PILL_PATTERNS = {
  'status', 'assignee', 'reviewer', 'type', 'priority', 'label', 'squad', 'application',
}
local HEADING_PATTERNS = {
  'name', 'title', 'id',
}

---@param key string
---@param patterns string[]
---@return boolean
local function matches_any(key, patterns)
  local lower = key:lower()
  for _, pattern in ipairs(patterns) do
    if lower:find(pattern, 1, true) then return true end
  end
  return false
end

---Classifies a `buffer.fields` key into a default rendering style. Never throws: any
---unexpected input (non-string, etc.) classifies as 'plain'.
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
