local config = require 'airtable.config'
local format_field = require('airtable.api').format_field

local M = {}

---Builds the markdown lines for a record from `buffer.fields`. The `title` key (if
---configured) becomes the H1 heading; every other key becomes its own section, titled
---with the key name capitalized (e.g. `tododev` -> "## Tododev").
---@param record AirtableRecord
---@return string[]
local function render_lines(record)
  local fields = config.options.buffer.fields
  local title = fields.title and format_field(record.fields[fields.title]) or ''
  if title == '' then title = '(untitled)' end

  local lines = { '# ' .. title, '' }

  -- pairs() iteration order isn't guaranteed for string keys; sort alphabetically so
  -- section order is stable across runs. (If explicit ordering matters, this can be
  -- revisited to use an ordered list instead of a plain table for `fields`.)
  local other_keys = {}
  for key in pairs(fields) do
    if key ~= 'title' then table.insert(other_keys, key) end
  end
  table.sort(other_keys)

  for _, key in ipairs(other_keys) do
    local field_name = fields[key]
    local text = format_field(record.fields[field_name])
    if text == '' then text = '_Empty._' end
    local heading = key:sub(1, 1):upper() .. key:sub(2)
    vim.list_extend(lines, { '## ' .. heading, '' })
    vim.list_extend(lines, vim.split(text, '\n', { plain = true }))
    table.insert(lines, '')
  end

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
