---@class AirtableFilter
---@field name string Display name shown in the picker/command completion
---@field formula string? Airtable `filterByFormula` expression, for complex conditions
---@field field string? Shorthand alternative to `formula`: Airtable field name to match exactly
---@field value string? Shorthand alternative to `formula`: value `field` must equal (used with `field`)

---@class AirtableFields
---@field title string Airtable field name used as the record title
---@field description string Airtable field name used as the record description

---@class AirtableDisplaySection
---@field field string Airtable field name to render in this section
---@field hl string? Highlight group for this section's text (default: a neutral comment color)

---@class AirtableConfig
---@field token_env string Name of the environment variable holding the Airtable personal access token
---@field base_id string Airtable base id (e.g. "appXXXXXXXXXXXXXX")
---@field table_name string Airtable table name or table id
---@field fields AirtableFields
---@field display AirtableDisplaySection[] Ordered list of fields shown as separate sections in the picker
---@field filters AirtableFilter[]
---@field default_filter string Name of the filter selected when none is passed to `open()`
---@field page_size integer Airtable page size (max 100)

local M = {}

local notify = require('airtable.notify').notify

---@type AirtableConfig
local defaults = {
  token_env = 'AIRTABLE_TOKEN',
  base_id = '',
  table_name = '',
  fields = {
    title = 'Name',
    description = 'Description',
  },
  display = {
    { field = 'Name', hl = 'TelescopeResultsIdentifier' },
  },
  filters = {
    { name = 'Assigned to me', field = 'Assignee', value = 'Your Name' },
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

---Resolves a filter's `formula`, building it from `field`/`value` when those are used
---instead of an explicit formula. Returns nil (and notifies) if the filter is malformed.
---@param filter AirtableFilter
---@return string?
local function resolve_formula(filter)
  if filter.formula then return filter.formula end
  if filter.field and filter.value then
    return string.format("{%s} = '%s'", filter.field, escape_formula_string(filter.value))
  end
  notify('Config Error', string.format('filter "%s" needs either "formula" or "field"+"value"', filter.name), vim.log.levels.ERROR)
  return nil
end

---Merges user options into the plugin defaults and validates required fields.
---@param opts AirtableConfig?
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

  -- If the user customized `fields.title` but not `display`, default the display
  -- section to that title field instead of the stale "Name" default.
  if opts.fields and opts.fields.title and not opts.display then
    M.options.display = { { field = opts.fields.title, hl = 'TelescopeResultsIdentifier' } }
  end

  if M.options.base_id == '' then
    notify('Config Error', '"base_id" is not set', vim.log.levels.ERROR)
  end
  if M.options.table_name == '' then
    notify('Config Error', '"table_name" is not set', vim.log.levels.ERROR)
  end
  if #M.options.filters == 0 then
    notify('Config Warning', 'no filters configured', vim.log.levels.WARN)
  end
  if #M.options.display == 0 then
    notify('Config Warning', 'no display sections configured', vim.log.levels.WARN)
  end
end

---Returns the configured filter matching `name` (with `formula` resolved from the
---`field`/`value` shorthand if used), or the default filter if `name` is nil.
---Returns nil (and notifies) if no filter matches or the matched filter is malformed.
---@param name string?
---@return AirtableFilter?
function M.get_filter(name)
  local target = name or M.options.default_filter
  for _, filter in ipairs(M.options.filters) do
    if filter.name == target then
      local formula = resolve_formula(filter)
      if not formula then return nil end
      return vim.tbl_extend('force', filter, { formula = formula })
    end
  end
  notify('Unknown Filter', string.format('no filter named "%s"', target), vim.log.levels.ERROR)
  return nil
end

---@return string[]
function M.filter_names()
  return vim.tbl_map(function(f) return f.name end, M.options.filters)
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
