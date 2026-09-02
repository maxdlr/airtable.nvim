local config = require 'airtable.config'
local view = require 'airtable.view'

local M = {}

---Builds the display string for a record entry in the picker.
---@param record AirtableRecord
---@return string
local function display_title(record)
  return record.fields[config.options.fields.title] or record.id
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
            display = display_title(record),
            ordinal = display_title(record),
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
