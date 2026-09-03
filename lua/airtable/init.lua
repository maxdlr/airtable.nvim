local config = require 'airtable.config'

local M = {}

---@param opts AirtableConfig?
function M.setup(opts)
  config.setup(opts)
end

---@return string[]
function M.picker_names()
  return config.picker_names()
end

---Opens the Telescope picker for the given picker name (or the configured default).
---@param picker_name string?
function M.open(picker_name)
  local picker = config.get_picker(picker_name)
  if not picker then
    -- config.get_picker already notified the specific reason (unknown name vs.
    -- malformed filter) via config.lua's own error path.
    return
  end

  require('airtable.picker').pick(picker, function(callback)
    require('airtable.api').list_records(picker.formula, picker.sort, callback)
  end)
end

return M
