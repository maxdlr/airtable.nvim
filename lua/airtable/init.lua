local config = require 'airtable.config'

local M = {}

---@param opts AirtableConfig?
function M.setup(opts)
  config.setup(opts)
end

---@return string[]
function M.filter_names()
  return config.filter_names()
end

---Opens the Telescope picker for the given filter name (or the configured default).
---@param filter_name string?
function M.open(filter_name)
  local filter = config.get_filter(filter_name)
  if not filter then
    vim.notify(
      string.format('[airtable.nvim] unknown filter "%s"', filter_name or config.options.default_filter),
      vim.log.levels.ERROR
    )
    return
  end

  require('airtable.api').list_records(filter.formula, function(records, err)
    if err then
      vim.notify('[airtable.nvim] ' .. err, vim.log.levels.ERROR)
      return
    end
    if #records == 0 then
      vim.notify(string.format('[airtable.nvim] no records for filter "%s"', filter.name), vim.log.levels.INFO)
      return
    end
    require('airtable.picker').pick(records, filter.name)
  end)
end

return M
