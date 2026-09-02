local config = require 'airtable.config'
local notify = require('airtable.notify').notify

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

  require('airtable.api').list_records(picker.formula, picker.sort, function(records, err)
    if err then
      notify(err.category, err.message, vim.log.levels.ERROR)
      return
    end
    if #records == 0 then
      notify('No Records', string.format('no records for picker "%s"', picker.name), vim.log.levels.INFO)
      return
    end
    require('airtable.picker').pick(records, picker.name, picker.result_line)
  end)
end

return M
