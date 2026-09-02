local view = require 'airtable.view'
local format_field = require('airtable.api').format_field

local M = {}

local entry_display = require 'telescope.pickers.entry_display'

---Default highlight groups by section position, used when a `result_line` entry omits
---`hl`: 1st section stands out as the identifier, 2nd as a secondary comment, everything
---after that as a plain comment.
local DEFAULT_HL_BY_POSITION = {
  'TelescopeResultsIdentifier',
  'TelescopeResultsSpecialComment',
}
local DEFAULT_HL_FALLBACK = 'TelescopeResultsComment'

---Cache of hex color -> generated highlight group name, so repeated colors (or repeated
---picker invocations) don't keep redefining the same highlight group.
local hex_hl_cache = {}

---Resolves a `result_line` section's `hl` to a highlight group name. Accepts either an
---existing highlight group name (used as-is) or a hex color like "#FFFFFF" (a highlight
---group is lazily created and cached for it). When `hl` is omitted, falls back to a
---sensible default based on the section's position (see `DEFAULT_HL_BY_POSITION`).
---@param hl string?
---@param position integer 1-based index of this section within its result_line
---@return string
local function resolve_hl(hl, position)
  if not hl then return DEFAULT_HL_BY_POSITION[position] or DEFAULT_HL_FALLBACK end
  if not hl:match '^#%x%x%x%x%x%x$' then return hl end

  local cached = hex_hl_cache[hl]
  if cached then return cached end

  local group = 'AirtableColor' .. hl:sub(2)
  vim.api.nvim_set_hl(0, group, { fg = hl })
  hex_hl_cache[hl] = group
  return group
end

---Builds the plain-text ordinal string (used for fuzzy matching) from all `result_line`
---sections, so search isn't limited to just the first section.
---@param record AirtableRecord
---@param result_line AirtableResultSection[]
---@return string
local function ordinal_text(record, result_line)
  local parts = {}
  for _, section in ipairs(result_line) do
    local text = format_field(record.fields[section.field])
    if text ~= '' then table.insert(parts, text) end
  end
  return table.concat(parts, ' ')
end

---Builds the segmented `display` function for a record entry, one section per
---`result_line` entry, separated by " │ ". Missing fields render as "—".
---All sections but the last auto-size to their content; the last fills remaining width.
---@param record AirtableRecord
---@param result_line AirtableResultSection[]
---@return function
local function make_display(record, result_line)
  local sections = {}
  for i, section in ipairs(result_line) do
    local text = format_field(record.fields[section.field])
    if text == '' then text = '—' end
    table.insert(sections, { text, resolve_hl(section.hl, i) })
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
---@param result_line AirtableResultSection[] Sections to render per result line
function M.pick(records, prompt_title, result_line)
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
            display = make_display(record, result_line),
            ordinal = ordinal_text(record, result_line),
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
