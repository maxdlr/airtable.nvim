---@class AirtableFilterCondition
---@field field string
---@field value string|string[] "any of these" (OR) if a list
---@field only boolean? Exact match instead of the default contains/FIND match
---@field by 'email'? Match a collaborator field's exact email instead of its display
---  name. Airtable's formula engine can't see a collaborator's email, so this condition
---  is applied client-side after fetching (can't be combined with a formula-only picker
---  that has zero other conditions to fall back to "list everything" for the API call).

---@class AirtableSort
---@field field string
---@field order 'asc'|'desc'?

---@class AirtableResultSectionColorRule
---@field value string
---@field color string

---@class AirtableResultSection
---@field field string
---@field hl string|AirtableResultSectionColorRule[]|nil Group name, hex color, or
---  per-value color rules. Defaults by position if omitted.
---@field date_format 'datetime'|'date'|'time'|nil

---@class AirtablePrefixIcon
---@field icon string
---@field color string?

---@class AirtablePicker
---@field name string
---@field filters AirtableFilterCondition[]? AND-ed. Omit to list all records.
---@field sort AirtableSort?
---@field result_line AirtableResultSection[]
---@field result_line_prefix {[1]: string|AirtablePrefixIcon, [2]: AirtableFilterCondition}[]?
---  First matching condition's icon is prepended to the result line.

---@class AirtableEditableField
---@field field string Must match a `buffer.fields` entry's `field`
---@field type 'select'|'text'
---@field name string? Menu label (default: "Edit <field>")

---@class AirtableBufferField
---@field key string Drives default styling (see `airtable.style.classify`).
---  `"title"` is special: rendered as the H1 heading.
---@field field string
---@field date_format 'datetime'|'date'|'time'|nil

---@class AirtableBufferStyle
---@field section_border_character string? Left border character for plain-style
---  sections (heading + body). Default: "▌"
---@field editable_section_border_color string? Hex color for the left border of
---  plain-style sections that are in `buffer.editable`. Default: "#FFA500" (orange)

---@class AirtableBufferConfig
---@field name { field: string }? Buffer name is "Airtable: <field value>" (default: "Airtable: <Title>")
---@field fields AirtableBufferField[] Rendered in this order (except `title`)
---@field editable AirtableEditableField[]? Write operation — only these fields are editable
---@field style AirtableBufferStyle?

---@class AirtableDateFormats
---@field datetime string? Placeholders: {DD} {MM} {YYYY} {HH} {mm}
---@field date string?
---@field time string?

---@class AirtableConfig
---@field token_env string Env var name holding the Airtable token
---@field base_id string
---@field table_name string
---@field buffer AirtableBufferConfig
---@field pickers AirtablePicker[]
---@field default_filter string Picker opened by `open()` with no argument
---@field page_size integer
---@field date_formats AirtableDateFormats?

local M = {}

local notify = require("airtable.notify").notify

---@type AirtableConfig
local defaults = {
	token_env = "AIRTABLE_TOKEN",
	base_id = "",
	table_name = "",
	buffer = {
		name = { field = "Title" },
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

local function escape_formula_string(value)
	return (value:gsub("'", "\\'"))
end

-- Default: FIND/ARRAYJOIN so this works on both plain and array-shaped fields.
-- only=true: exact `=` match instead.
local function single_match_formula(field, value, only)
	local escaped = escape_formula_string(tostring(value))
	if only then
		return string.format("{%s} = '%s'", field, escaped)
	end
	return string.format("FIND('%s', ARRAYJOIN({%s})) > 0", escaped, field)
end

local function condition_formula(condition)
	if type(condition.value) == "table" then
		local alternatives = vim.tbl_map(function(v)
			return single_match_formula(condition.field, v, condition.only)
		end, condition.value)
		return string.format("OR(%s)", table.concat(alternatives, ", "))
	end
	return single_match_formula(condition.field, condition.value, condition.only)
end

-- by = 'email' conditions can't be turned into a formula (Airtable's formula engine
-- can't see a collaborator's email) — they're applied client-side, see M.filter_records.
local function formula_eligible(condition)
	return condition.by ~= "email"
end

local function build_formula(picker)
	local filters = vim.tbl_filter(formula_eligible, picker.filters or {})
	if #filters == 0 then
		return nil
	end
	if #filters == 1 then
		return condition_formula(filters[1])
	end
	local parts = vim.tbl_map(condition_formula, filters)
	return string.format("AND(%s)", table.concat(parts, ", "))
end

-- Mirrors condition_formula's semantics so client-side matching (result_line_prefix)
-- behaves the same as the server-side formula.
local function value_matches(actual_text, expected, only)
	expected = tostring(expected)
	if only then
		return actual_text == expected
	end
	return actual_text:find(expected, 1, true) ~= nil
end

-- Extracts the email(s) from a raw collaborator field value: {id,email,name} (single)
-- or an array of those. Always an exact match — "contains" doesn't make sense for emails.
local function emails_from_field(raw_value)
	if type(raw_value) ~= "table" then
		return {}
	end
	if raw_value.email then
		return { raw_value.email }
	end
	local emails = {}
	for _, item in ipairs(raw_value) do
		if type(item) == "table" and item.email then
			table.insert(emails, item.email)
		end
	end
	return emails
end

local function email_matches(raw_value, expected)
	for _, email in ipairs(emails_from_field(raw_value)) do
		if email == expected then
			return true
		end
	end
	return false
end

function M.matches_condition(record, condition)
	if condition.by == "email" then
		local raw_value = record.fields[condition.field]
		if type(condition.value) == "table" then
			for _, v in ipairs(condition.value) do
				if email_matches(raw_value, v) then
					return true
				end
			end
			return false
		end
		return email_matches(raw_value, condition.value)
	end

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

-- Applies a picker's by='email' filter conditions to an already-fetched records list
-- (the only conditions not already covered by the API-side formula). AND-ed together,
-- same as the formula, so combining an email filter with a regular one narrows results.
---@param records AirtableRecord[]
---@param picker AirtablePicker
---@return AirtableRecord[]
function M.filter_records(records, picker)
	local email_conditions = vim.tbl_filter(function(c)
		return c.by == "email"
	end, picker.filters or {})
	if #email_conditions == 0 then
		return records
	end

	return vim.tbl_filter(function(record)
		for _, condition in ipairs(email_conditions) do
			if not M.matches_condition(record, condition) then
				return false
			end
		end
		return true
	end, records)
end

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
		for _, condition in ipairs(picker.filters or {}) do
			if condition.by and condition.by ~= "email" then
				notify(
					"Config Error",
					string.format('picker "%s" has a filter with invalid "by" value "%s" (expected "email")', picker.name, tostring(condition.by)),
					vim.log.levels.ERROR
				)
			end
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

	local style = M.options.buffer.style
	if style and style.section_border_character then
		if type(style.section_border_character) ~= "string" or style.section_border_character == "" then
			notify(
				"Config Error",
				'"buffer.style.section_border_character" must be a non-empty string',
				vim.log.levels.ERROR
			)
		end
	end
	if style and style.editable_section_border_color then
		if
			type(style.editable_section_border_color) ~= "string"
			or not style.editable_section_border_color:match("^#%x%x%x%x%x%x$")
		then
			notify(
				"Config Error",
				'"buffer.style.editable_section_border_color" must be a hex color like "#FFA500"',
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

function M.picker_names()
	return vim.tbl_map(function(p)
		return p.name
	end, M.options.pickers)
end

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
