---@class AirtableFilterCondition
---@field field string Airtable field name to match
---@field value string|string[] Value `field` must equal/contain. A list means "any of these" (OR).
---@field contains boolean? Set true for array-shaped fields (linked records, multi-select,
---  collaborators) where `field` holds multiple values under the hood and exact `=` can't
---  match — uses `FIND(value, ARRAYJOIN(field)) > 0` instead of `field = value`.

---@class AirtableSort
---@field field string Airtable field name to sort by
---@field order 'asc'|'desc'?  Sort direction (default: 'asc')

---@class AirtableResultSection
---@field field string Airtable field name to render in this section
---@field hl string? Highlight group name, or a hex color like "#FFFFFF" (a highlight group
---  is created automatically for hex colors). If omitted, defaults by position: 1st section
---  -> "TelescopeResultsIdentifier", 2nd -> "TelescopeResultsSpecialComment", others ->
---  "TelescopeResultsComment".

---@class AirtablePicker
---@field name string Display name shown in the picker/command completion
---@field filters AirtableFilterCondition[]? Conditions combined with AND. Omit to list all records.
---@field sort AirtableSort? How to order results (translated to Airtable's `sort[]` API param)
---@field result_line AirtableResultSection[] Ordered sections shown in this picker's result line

---@class AirtableBufferConfig
---@field fields table<string, string> Arbitrary named fields to render in the record buffer.
---  The `title` key (if present) is rendered as the H1 heading; every other key becomes its
---  own markdown section, titled with the key name.

---@class AirtableConfig
---@field token_env string Name of the environment variable holding the Airtable personal access token
---@field base_id string Airtable base id (e.g. "appXXXXXXXXXXXXXX")
---@field table_name string Airtable table name or table id
---@field buffer AirtableBufferConfig
---@field pickers AirtablePicker[]
---@field default_filter string Name of the picker (from `pickers`) opened when none is passed to `open()`
---@field page_size integer Airtable page size (max 100)

local M = {}

local notify = require('airtable.notify').notify

---@type AirtableConfig
local defaults = {
  token_env = 'AIRTABLE_TOKEN',
  base_id = '',
  table_name = '',
  buffer = {
    fields = {
      title = 'Name',
      description = 'Description',
    },
  },
  pickers = {
    {
      name = 'Assigned to me',
      filters = { { field = 'Assignee', value = 'Your Name', contains = true } },
      result_line = { { field = 'Name' } },
    },
  },
  default_filter = 'Assigned to me',
  page_size = 100,
}

---@type AirtableConfig
M.options = vim.deepcopy(defaults)

---Escapes single quotes for use inside an Airtable formula string literal.
---@param value string
---@return string
local function escape_formula_string(value) return (value:gsub("'", "\\'")) end

---Builds a single `field OP value` comparison, using exact `=` match or, for
---array-shaped fields (`contains = true`), `FIND(value, ARRAYJOIN(field)) > 0`.
---@param field string
---@param value string
---@param contains boolean?
---@return string
local function single_match_formula(field, value, contains)
  local escaped = escape_formula_string(tostring(value))
  if contains then return string.format("FIND('%s', ARRAYJOIN({%s})) > 0", escaped, field) end
  return string.format("{%s} = '%s'", field, escaped)
end

---Builds the formula fragment for one condition. A list `value` becomes an `OR` of
---matches on that field; a plain string/number becomes a single match.
---@param condition AirtableFilterCondition
---@return string
local function condition_formula(condition)
  if type(condition.value) == 'table' then
    local alternatives =
      vim.tbl_map(function(v) return single_match_formula(condition.field, v, condition.contains) end, condition.value)
    return string.format('OR(%s)', table.concat(alternatives, ', '))
  end
  return single_match_formula(condition.field, condition.value, condition.contains)
end

---Builds a picker's full `filterByFormula` expression by AND-ing all its conditions.
---Returns nil (matches all records) when the picker has no filters.
---@param picker AirtablePicker
---@return string?
local function build_formula(picker)
  if not picker.filters or #picker.filters == 0 then return nil end
  if #picker.filters == 1 then return condition_formula(picker.filters[1]) end
  local parts = vim.tbl_map(condition_formula, picker.filters)
  return string.format('AND(%s)', table.concat(parts, ', '))
end

---Merges user options into the plugin defaults and validates required fields.
---@param opts AirtableConfig?
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

  if M.options.base_id == '' then
    notify('Config Error', '"base_id" is not set', vim.log.levels.ERROR)
  end
  if M.options.table_name == '' then
    notify('Config Error', '"table_name" is not set', vim.log.levels.ERROR)
  end
  if #M.options.pickers == 0 then
    notify('Config Warning', 'no pickers configured', vim.log.levels.WARN)
  end
  for _, picker in ipairs(M.options.pickers) do
    if not picker.result_line or #picker.result_line == 0 then
      notify('Config Warning', string.format('picker "%s" has no result_line configured', picker.name), vim.log.levels.WARN)
    end
  end
end

---Returns the configured picker matching `name` (with `formula` resolved from its
---`filters`), or the default picker if `name` is nil. Returns nil (and notifies) if
---no picker matches.
---@param name string?
---@return (AirtablePicker & { formula: string? })?
function M.get_picker(name)
  local target = name or M.options.default_filter
  for _, picker in ipairs(M.options.pickers) do
    if picker.name == target then return vim.tbl_extend('force', picker, { formula = build_formula(picker) }) end
  end
  notify('Unknown Picker', string.format('no picker named "%s"', target), vim.log.levels.ERROR)
  return nil
end

---@return string[]
function M.picker_names()
  return vim.tbl_map(function(p) return p.name end, M.options.pickers)
end

---Reads the Airtable personal access token from the configured environment variable.
---@return string?
function M.token()
  local value = os.getenv(M.options.token_env)
  if not value or value == '' then
    notify('Missing Token', string.format('environment variable "%s" is not set', M.options.token_env), vim.log.levels.ERROR)
    return nil
  end
  return value
end

return M
