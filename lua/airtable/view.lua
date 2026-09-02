local config = require 'airtable.config'

local M = {}

---Builds the markdown lines for a record using the configured title/description fields.
---@param record AirtableRecord
---@return string[]
local function render_lines(record)
  local fields = config.options.fields
  local title = record.fields[fields.title] or '(untitled)'
  local description = record.fields[fields.description] or '_No description._'

  local lines = { '# ' .. title, '' }
  vim.list_extend(lines, vim.split(description, '\n', { plain = true }))
  return lines
end

---Opens a non-writable scratch buffer showing the record formatted as markdown.
---@param record AirtableRecord
function M.open(record)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(record))

  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, 'airtable://' .. record.id)

  vim.api.nvim_set_current_buf(buf)
end

return M
