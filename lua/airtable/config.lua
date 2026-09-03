---@class AirtableFilterCondition
---@field field string Airtable field name to match
---@field value string|string[] Value `field` must equal/contain. A list means "any of these" (OR).
---@field only boolean? By default, conditions match array-shaped fields too (linked records,
---  multi-select, collaborators) using `FIND(value, ARRAYJOIN(field)) > 0`, since that also
---  works correctly for plain text/number/single-select fields. Set `only = true` to force
---  an exact `field = value` comparison instead — needed if `value` could be a substring of
---  another value in the same field (e.g. matching 'Bug' when 'Bug report' also exists).

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
---@field result_line_prefix {[1]: string, [2]: AirtableFilterCondition}[]? Advanced/optional:
---  an ordered list of `{ icon, condition }` pairs. For each record, the first condition
---  that matches has its icon prepended to the result line; records matching no condition
---  get no prefix. Evaluated client-side against already-fetched data — no extra requests.

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
      title = 'Title',
      description = 'Description',
    },
  },
  pickers = {
    {
      name = 'All records',
      result_line = { { field = 'Title' } },
    },
  },
  default_filter = 'All records',
  page_size = 100,
}

---@type AirtableConfig
M.options = vim.deepcopy(defaults)

---Escapes single quotes for use inside an Airtable formula string literal.
---@param value string
---@return string
local function escape_formula_string(value) return (value:gsub("'", "\\'")) end

---Builds a single `field OP value` comparison. By default uses `FIND(value,
---ARRAYJOIN(field)) > 0`, which works for both array-shaped fields (linked records,
---multi-select, collaborators) and plain text/number/single-select fields. Pass
---`only = true` for an exact `field = value` comparison instead.
---@param field string
---@param value string
---@param only boolean?
---@return string
local function single_match_formula(field, value, only)
  local escaped = escape_formula_string(tostring(value))
  if only then return string.format("{%s} = '%s'", field, escaped) end
  return string.format("FIND('%s', ARRAYJOIN({%s})) > 0", escaped, field)
end

---Builds the formula fragment for one condition. A list `value` becomes an `OR` of
---matches on that field; a plain string/number becomes a single match.
---@param condition AirtableFilterCondition
---@return string
local function condition_formula(condition)
  if type(condition.value) == 'table' then
    local alternatives =
      vim.tbl_map(function(v) return single_match_formula(condition.field, v, condition.only) end, condition.value)
    return string.format('OR(%s)', table.concat(alternatives, ', '))
  end
  return single_match_formula(condition.field, condition.value, condition.only)
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

---Checks whether a single value matches a condition's expected value, mirroring the
---server-side formula semantics: substring match by default, exact match when `only` is
---set. Comparison is done on the plain-text form of the record's raw field value, via the
---same formatter used for display (`airtable.api.format_field`), so array-shaped fields
---(collaborators, linked records, multi-select) are handled the same way here as server-side.
---@param actual_text string
---@param expected string
---@param only boolean?
---@return boolean
local function value_matches(actual_text, expected, only)
  expected = tostring(expected)
  if only then return actual_text == expected end
  return actual_text:find(expected, 1, true) ~= nil
end

---Checks whether `record` matches a filter condition, client-side. Used by
---`result_line_prefix` to pick an icon without an extra API round-trip. Mirrors
---`condition_formula`'s semantics (contains-by-default, `only` for exact, list `value`
---for OR) so a condition behaves the same whether sent to Airtable or evaluated locally.
---@param record AirtableRecord
---@param condition AirtableFilterCondition
---@return boolean
function M.matches_condition(record, condition)
  local format_field = require('airtable.api').format_field
  local actual_text = format_field(record.fields[condition.field])

  if type(condition.value) == 'table' then
    for _, v in ipairs(condition.value) do
      if value_matches(actual_text, v, condition.only) then return true end
    end
    return false
  end
  return value_matches(actual_text, condition.value, condition.only)
end

---Resolves a picker's `result_line_prefix` icon for `record`: the icon of the first
---condition that matches, or "" if none match or `result_line_prefix` is unset.
---@param record AirtableRecord
---@param picker AirtablePicker
---@return string
function M.resolve_prefix_icon(record, picker)
  if not picker.result_line_prefix then return '' end
  for _, rule in ipairs(picker.result_line_prefix) do
    local icon, condition = rule[1], rule[2]
    if M.matches_condition(record, condition) then return icon end
  end
  return ''
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
