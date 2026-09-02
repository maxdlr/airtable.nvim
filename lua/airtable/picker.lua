local config = require 'airtable.config'
local view = require 'airtable.view'

local M = {}

local entry_display = require 'telescope.pickers.entry_display'

---Builds the plain-text ordinal string (used for fuzzy matching) from all configured
---display sections, so search isn't limited to just the title.
---@param record AirtableRecord
---@return string
local function ordinal_text(record)
  local parts = {}
  for _, section in ipairs(config.options.display) do
    local value = record.fields[section.field]
    if value ~= nil and value ~= '' then table.insert(parts, tostring(value)) end
  end
  return table.concat(parts, ' ')
end

---Builds the segmented `display` function for a record entry, one section per
---configured display field, separated by " │ ". Missing fields are skipped.
---All sections but the last auto-size to their content; the last fills remaining width.
---@param record AirtableRecord
---@return function
local function make_display(record)
  local sections = {}
  for _, section in ipairs(config.options.display) do
    local value = record.fields[section.field]
    if value == nil or value == '' then value = '—' end
    table.insert(sections, { tostring(value), section.hl or 'Comment' })
  end

  local items = {}
  for i = 1, #sections do
    items[i] = i == #sections and { remaining = true } or { width = nil }
  end

  local displayer = entry_display.create {
    separator = ' │ ',
    items = items,
  }

  return function() return displayer(sections) end
end

---Opens a Telescope picker listing `records`; selecting an entry opens the record view buffer.
---@param records AirtableRecord[]
---@param prompt_title string
function M.pick(records, prompt_title)
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'

  pickers
    .new({}, {
      prompt_title = prompt_title,
      finder = finders.new_table {
        results = records,
        entry_maker = function(record)
          return {
            value = record,
            display = make_display(record),
            ordinal = ordinal_text(record),
          }
        end,
      },
      sorter = conf.generic_sorter {},
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then view.open(selection.value) end
        end)
        return true
      end,
    })
    :find()
end

return M
