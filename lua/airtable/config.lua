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

---@class AirtableResultSectionColorRule
---@field value string Exact value to match against this section's displayed text
---@field color string Highlight group name, or a hex color like "#FFFFFF", used when `value` matches

---@class AirtableResultSection
---@field field string Airtable field name to render in this section
---@field hl string|AirtableResultSectionColorRule[]|nil Highlight group name, a hex color
---  like "#FFFFFF" (a highlight group is created automatically for hex colors), or a list
---  of `{ value, color }` rules — the first rule whose `value` exactly matches this
---  section's text wins. If omitted (or no rule matches), defaults by position: 1st
---  section -> "TelescopeResultsIdentifier", 2nd -> "TelescopeResultsSpecialComment",
---  others -> "TelescopeResultsComment".
---@field date_format 'datetime'|'date'|'time'|nil Same as `AirtableBufferField.date_format`
---  — reformats an Airtable ISO-8601 timestamp for display in this result-line section.

---@class AirtablePrefixIcon
---@field icon string The icon/glyph to render
---@field color string? Highlight group name, or a hex color like "#FFFFFF" (a highlight
---  group is created automatically for hex colors). Defaults to no special coloring.

---@class AirtablePicker
---@field name string Display name shown in the picker/command completion
---@field filters AirtableFilterCondition[]? Conditions combined with AND. Omit to list all records.
---@field sort AirtableSort? How to order results (translated to Airtable's `sort[]` API param)
---@field result_line AirtableResultSection[] Ordered sections shown in this picker's result line
---@field result_line_prefix {[1]: string|AirtablePrefixIcon, [2]: AirtableFilterCondition}[]?
---  Advanced/optional: an ordered list of `{ icon, condition }` pairs. `icon` is either a
---  plain string, or a `{ icon = ..., color = ... }` table to color it. For each record, the
---  first condition that matches has its icon prepended to the result line; records
---  matching no condition get no prefix. Evaluated client-side against already-fetched
---  data — no extra requests.

---@class AirtableEditableField
---@field field string Airtable field name (must match one of `buffer.fields`' `field`
---  values for this field to render correctly after editing) that this action edits
---@field type 'select'|'text' 'select' opens a Telescope picker of the field's choices
---  (fetched via Airtable's metadata API); 'text' opens a floating scratch buffer
---  prefilled with the current value — save with `<C-CR>`.
---@field name string? Display name for the context menu entry (default: "Edit <field>")

---@class AirtableBufferField
---@field key string Canonical name driving default styling (see `airtable.style.classify`)
---  — e.g. "title", "status", "assignee". `key = "title"` is special: rendered as the H1
---  heading instead of its own section, regardless of position in the list.
---@field field string Airtable field name to read this section's value from
---@field date_format 'datetime'|'date'|'time'|nil When set, the field's value is parsed as
---  an Airtable ISO-8601 timestamp (e.g. "2026-09-03T21:09:34.000Z") and reformatted:
---  'datetime' -> "03/09/2026 - 21:09", 'date' -> "03/09/2026", 'time' -> "21:09". A value
---  that isn't a valid ISO timestamp is left as-is rather than breaking the render.

---@class AirtableBufferConfig
---@field fields AirtableBufferField[] Ordered list of `{ key, field }` entries rendered
---  when a record is opened, in the given order (except `key = "title"`, always the H1
---  heading). `key` drives default styling by name pattern; `field` is the Airtable
---  column name.
---@field editable AirtableEditableField[]? Fields that can be edited from the record view's
---  `<CR>` context menu. This is a **write** operation against your Airtable base — only
---  fields explicitly listed here are ever editable. Omit entirely to keep the plugin
---  fully read-only.

---@class AirtableDateFormats
---@field datetime string? Template for `date_format = 'datetime'`. Placeholders: `{DD}`,
---  `{MM}`, `{YYYY}`, `{HH}`, `{mm}`. Default: `"{DD}/{MM}/{YYYY} - {HH}:{mm}"`.
---@field date string? Template for `date_format = 'date'`. Default: `"{DD}/{MM}/{YYYY}"`.
---@field time string? Template for `date_format = 'time'`. Default: `"{HH}:{mm}"`.

---@class AirtableConfig
---@field token_env string Name of the environment variable holding the Airtable personal access token
---@field base_id string Airtable base id (e.g. "appXXXXXXXXXXXXXX")
---@field table_name string Airtable table name or table id
---@field buffer AirtableBufferConfig
---@field pickers AirtablePicker[]
---@field default_filter string Name of the picker (from `pickers`) opened when none is passed to `open()`
---@field page_size integer Airtable page size (max 100)
---@field date_formats AirtableDateFormats? Advanced/optional: overrides the display
---  template for each `date_format` mode, applied everywhere a `date_format` is used
---  (explicitly, or auto-detected — see `AirtableBufferField.date_format`).

local M = {}

local notify = require("airtable.notify").notify

---@type AirtableConfig
local defaults = {
	token_env = "AIRTABLE_TOKEN",
	base_id = "",
	table_name = "",
	buffer = {
		fields = {
			{ key = "title", field = "Title" },
			{ key = "status", field = "Status" },
			{ key = "description", field = "Description" },
		},
	},
	pickers = {
		{
			name = "All records",
			result_line = { { field = "Status" }, { field = "Title" }, { field = "Description" } },
		},
	},
	default_filter = "All records",
	page_size = 20,
}

---@type AirtableConfig
M.options = vim.deepcopy(defaults)

---Escapes single quotes for use inside an Airtable formula string literal.
---@param value string
---@return string
local function escape_formula_string(value)
	return (value:gsub("'", "\\'"))
end

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
	if only then
		return string.format("{%s} = '%s'", field, escaped)
	end
	return string.format("FIND('%s', ARRAYJOIN({%s})) > 0", escaped, field)
end

---Builds the formula fragment for one condition. A list `value` becomes an `OR` of
---matches on that field; a plain string/number becomes a single match.
---@param condition AirtableFilterCondition
---@return string
local function condition_formula(condition)
	if type(condition.value) == "table" then
		local alternatives = vim.tbl_map(function(v)
			return single_match_formula(condition.field, v, condition.only)
		end, condition.value)
		return string.format("OR(%s)", table.concat(alternatives, ", "))
	end
	return single_match_formula(condition.field, condition.value, condition.only)
end

---Builds a picker's full `filterByFormula` expression by AND-ing all its conditions.
---Returns nil (matches all records) when the picker has no filters.
---@param picker AirtablePicker
---@return string?
local function build_formula(picker)
	if not picker.filters or #picker.filters == 0 then
		return nil
	end
	if #picker.filters == 1 then
		return condition_formula(picker.filters[1])
	end
	local parts = vim.tbl_map(condition_formula, picker.filters)
	return string.format("AND(%s)", table.concat(parts, ", "))
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
	if only then
		return actual_text == expected
	end
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
	local format_field = require("airtable.api").format_field
	local actual_text = format_field(record.fields[condition.field])

	if type(condition.value) == "table" then
		for _, v in ipairs(condition.value) do
			if value_matches(actual_text, v, condition.only) then
				return true
			end
		end
		return false
	end
	return value_matches(actual_text, condition.value, condition.only)
end

---Resolves a picker's `result_line_prefix` icon spec for `record`: the icon of the first
---condition that matches (a plain string, or a `{ icon, color }` table — see
---`AirtablePrefixIcon`), or "" if none match or `result_line_prefix` is unset. Returned
---as-is/unresolved; rendering (e.g. turning `color` into a highlight group) is the
---caller's responsibility.
---@param record AirtableRecord
---@param picker AirtablePicker
---@return string|AirtablePrefixIcon
function M.resolve_prefix_icon(record, picker)
	if not picker.result_line_prefix then
		return ""
	end
	for _, rule in ipairs(picker.result_line_prefix) do
		local icon, condition = rule[1], rule[2]
		if M.matches_condition(record, condition) then
			return icon
		end
	end
	return ""
end

---Merges user options into the plugin defaults and validates required fields.
---@param opts AirtableConfig?
function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

	if M.options.base_id == "" then
		notify("Config Error", '"base_id" is not set', vim.log.levels.ERROR)
	end
	if M.options.table_name == "" then
		notify("Config Error", '"table_name" is not set', vim.log.levels.ERROR)
	end
	if #M.options.pickers == 0 then
		notify("Config Warning", "no pickers configured", vim.log.levels.WARN)
	end
	for _, picker in ipairs(M.options.pickers) do
		if not picker.result_line or #picker.result_line == 0 then
			notify(
				"Config Warning",
				string.format('picker "%s" has no result_line configured', picker.name),
				vim.log.levels.WARN
			)
		end
	end

	for _, buffer_field in ipairs(M.options.buffer.fields or {}) do
		if not buffer_field.key or buffer_field.key == "" then
			notify("Config Error", 'a "buffer.fields" entry is missing "key"', vim.log.levels.ERROR)
		end
		if not buffer_field.field or buffer_field.field == "" then
			notify(
				"Config Error",
				string.format('"buffer.fields" entry "%s" is missing "field"', tostring(buffer_field.key)),
				vim.log.levels.ERROR
			)
		end
		if
			buffer_field.date_format and not vim.tbl_contains({ "datetime", "date", "time" }, buffer_field.date_format)
		then
			notify(
				"Config Error",
				string.format(
					'"buffer.fields" entry "%s" has invalid date_format "%s" (expected "datetime", "date", or "time")',
					tostring(buffer_field.key),
					tostring(buffer_field.date_format)
				),
				vim.log.levels.ERROR
			)
		end
	end

	if M.options.date_formats then
		for mode, template in pairs(M.options.date_formats) do
			if not vim.tbl_contains({ "datetime", "date", "time" }, mode) then
				notify(
					"Config Error",
					string.format(
						'"date_formats" has unknown key "%s" (expected "datetime", "date", or "time")',
						tostring(mode)
					),
					vim.log.levels.ERROR
				)
			elseif type(template) ~= "string" or template == "" then
				notify(
					"Config Error",
					string.format('"date_formats.%s" must be a non-empty string', mode),
					vim.log.levels.ERROR
				)
			end
		end
	end

	for _, editable in ipairs(M.options.buffer.editable or {}) do
		if not editable.field or editable.field == "" then
			notify("Config Error", 'a "buffer.editable" entry is missing "field"', vim.log.levels.ERROR)
		end
		if editable.type ~= "select" and editable.type ~= "text" then
			notify(
				"Config Error",
				string.format(
					'"buffer.editable" entry for "%s" needs type "select" or "text", got "%s"',
					tostring(editable.field),
					tostring(editable.type)
				),
				vim.log.levels.ERROR
			)
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
		if picker.name == target then
			return vim.tbl_extend("force", picker, { formula = build_formula(picker) })
		end
	end
	notify("Unknown Picker", string.format('no picker named "%s"', target), vim.log.levels.ERROR)
	return nil
end

---@return string[]
function M.picker_names()
	return vim.tbl_map(function(p)
		return p.name
	end, M.options.pickers)
end

---Reads the Airtable personal access token from the configured environment variable.
---@return string?
function M.token()
	local value = os.getenv(M.options.token_env)
	if not value or value == "" then
		notify(
			"Missing Token",
			string.format('environment variable "%s" is not set', M.options.token_env),
			vim.log.levels.ERROR
		)
		return nil
	end
	return value
end

return M
