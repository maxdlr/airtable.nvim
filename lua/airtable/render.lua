-- Pure layout: record -> buffer lines + decoration extmarks + editable region specs.
-- Shared by the picker preview (read-only) and the record buffer (editable). Never
-- touches a buffer itself; see `apply_extmarks` and `airtable.regions` for that.

local config = require("airtable.config")
local api = require("airtable.api")
local style = require("airtable.style")
local colors = require("airtable.colors")
local bubble = require("airtable.bubble")
local format_field = api.format_field

local M = {}

M.EMPTY = "_Empty._"
M.UNTITLED = "(untitled)"

local DEFAULT_LEFT_BORDER = "▌ "
local LEFT_BORDER_HL = "Comment"
local DEFAULT_EDITABLE_BORDER_COLOR = "#FFA500"

-- Airtable field types whose value is a single line of text in the API.
M.SINGLE_LINE_TYPES = {
	singleLineText = true,
	url = true,
	email = true,
	phoneNumber = true,
	number = true,
	currency = true,
	percent = true,
}

-- Airtable field types that can be edited as plain text in the buffer.
M.INLINE_TYPES = vim.tbl_extend("force", M.SINGLE_LINE_TYPES, {
	multilineText = true,
	richText = true,
})

M.NUMERIC_TYPES = { number = true, currency = true, percent = true }

---@class AirtableRegionSpec
---@field key string buffer.fields key
---@field field string Airtable field name
---@field kind 'inline'|'block' inline: starts mid-line after a prefix (title, "Key: ").
---  block: whole lines (plain sections), always starts at col 0 and ends at eol.
---@field start_row integer 0-based
---@field start_col integer 0-based byte col
---@field end_row integer
---@field end_col integer exclusive
---@field baseline string Value as last known on Airtable, in buffer-text form
---@field field_type string? Airtable field type, if the schema was available
---@field single_line boolean
---@field placeholder string Shown when the region is empty
---@field hl string? Highlight applied over the region's text
---@field border { [1]: string, [2]: string }? Left border drawn on each row (block only)

---@class AirtableLayout
---@field lines string[]
---@field extmarks { line: integer, col: integer, opts: table }[]
---@field regions AirtableRegionSpec[]
---@field sections { key: string, row: integer }[] First row of each section, in order

function M.left_border()
	local s = config.options.buffer.style
	return (s and s.section_border_character) or DEFAULT_LEFT_BORDER
end

-- Sections listed in buffer.editable (any type) get a distinct border color.
---@param field string
---@return string highlight_group
function M.border_hl(field)
	if not config.editable_entry(field) then
		return LEFT_BORDER_HL
	end
	local s = config.options.buffer.style
	local color = (s and s.editable_section_border_color) or DEFAULT_EDITABLE_BORDER_COLOR
	return colors.create_foreground_highlight(color)
end

local function heading_for(key)
	return key:sub(1, 1):upper() .. key:sub(2)
end

---@param heading string
---@param text string
---@param border string
---@param border_hl string
---@return { [1]: string, [2]: string }[]
local function pill_line_chunks(heading, text, border, border_hl)
	if text == M.EMPTY then
		return { { border, border_hl }, { heading .. ": ", "Title" }, { text, "Comment" } }
	end

	local ok, chunks = pcall(function()
		local hex = colors.color_for_value(text)
		local pill_chunks = bubble.make_bubble(text, hex)
		local result = { { border, border_hl }, { heading .. " ", "Title" } }
		vim.list_extend(result, pill_chunks)
		return result
	end)
	if ok then
		return chunks
	end
	return { { border, border_hl }, { heading .. ": " .. text, "Normal" } }
end

local function display_text(raw_value, date_format, default_mode)
	local text = format_field(raw_value)
	if text ~= "" then
		local mode = date_format or (api.looks_like_date(text) and default_mode or nil)
		if mode then
			text = api.format_date(text, mode)
		end
	end
	return text
end

local function border_mark(row, border, border_hl)
	return {
		line = row,
		col = 0,
		opts = { virt_text = { { border, border_hl } }, virt_text_pos = "inline", right_gravity = false },
	}
end

---@param record AirtableRecord
---@param opts { exclude: table<string, boolean>?, skip_missing: boolean?, editable: boolean?, field_types: table<string, string>?, values: table<string, string>? }?
---  editable: produce editable regions for `type = "text"` buffer.editable fields.
---  field_types: field name -> Airtable type, used to reject non-text fields and to
---    detect single-line fields. Unknown types are treated as multi-line text.
---  values: field name -> buffer text overriding the record's value (unsaved edits).
---@return AirtableLayout
function M.layout(record, opts)
	opts = opts or {}
	local exclude = opts.exclude or {}
	local values = opts.values or {}
	local field_types = opts.field_types or {}
	local fields = config.options.buffer.fields

	local lines, extmarks, regions, sections = {}, {}, {}, {}

	local function is_inline(field)
		if not opts.editable or not config.is_inline_editable(field) then
			return false
		end
		local field_type = field_types[field]
		return field_type == nil or M.INLINE_TYPES[field_type] == true
	end

	local function add_region(entry, spec)
		spec.key = entry.key
		spec.field = entry.field
		spec.field_type = field_types[entry.field]
		table.insert(regions, spec)
	end

	-- Title (H1) --------------------------------------------------------------------
	local title_entry
	for _, entry in ipairs(fields) do
		if entry.key == "title" then
			title_entry = entry
			break
		end
	end
	table.insert(sections, { key = "title", row = 0 })

	if title_entry and is_inline(title_entry.field) then
		local baseline = (format_field(record.fields[title_entry.field]):gsub("\n", " "))
		local text = ((values[title_entry.field] or baseline):gsub("\n", " "))
		lines = { "# " .. text, "" }
		add_region(title_entry, {
			kind = "inline",
			start_row = 0,
			start_col = 2,
			end_row = 0,
			end_col = 2 + #text,
			baseline = baseline,
			single_line = true,
			placeholder = M.UNTITLED,
		})
	else
		local title = title_entry and display_text(record.fields[title_entry.field], title_entry.date_format, nil) or ""
		if title == "" then
			title = M.UNTITLED
		end
		lines = { "# " .. title, "" }
	end

	if title_entry and config.editable_entry(title_entry.field) then
		table.insert(extmarks, {
			line = 0,
			col = 0,
			opts = { virt_text = { { M.left_border(), M.border_hl(title_entry.field) } }, virt_text_pos = "inline" },
		})
	end

	-- Other sections ----------------------------------------------------------------
	for _, entry in ipairs(fields) do
		local key = entry.key
		local field = entry.field
		if key == "title" or exclude[key] then
			goto continue
		end

		local raw_value = record.fields[field]
		if raw_value == nil and opts.skip_missing then
			goto continue
		end

		local heading = heading_for(key)
		local section_style = style.classify(key)
		local border = M.left_border()
		local border_hl = M.border_hl(field)
		table.insert(sections, { key = key, row = #lines })

		if is_inline(field) then
			local baseline = format_field(raw_value)
			local single_line = M.SINGLE_LINE_TYPES[field_types[field] or ""] == true
			local text = values[field] or baseline
			if single_line then
				text = text:gsub("\n", " ")
			end
			local body = vim.split(text, "\n", { plain = true })

			if section_style == "heading" then
				local prefix = heading .. ": "
				table.insert(lines, "")
				local start_row = #lines
				table.insert(lines, prefix .. body[1])
				for i = 2, #body do
					table.insert(lines, body[i])
				end
				local end_row = #lines - 1
				table.insert(extmarks, { line = start_row, col = 0, opts = { hl_group = "Title", end_col = #prefix } })
				add_region(entry, {
					kind = "inline",
					start_row = start_row,
					start_col = #prefix,
					end_row = end_row,
					end_col = #lines[end_row + 1],
					baseline = baseline,
					single_line = single_line,
					placeholder = M.EMPTY,
					hl = "Title",
				})
				table.insert(lines, "")
			else
				-- Pill-classified keys render as plain sections when inline-editable:
				-- a pill is virtual text, which can't be typed into.
				table.insert(lines, "## " .. heading)
				table.insert(extmarks, border_mark(#lines - 1, border, border_hl))
				table.insert(lines, "")
				table.insert(extmarks, border_mark(#lines - 1, border, border_hl))
				local start_row = #lines
				vim.list_extend(lines, body)
				local end_row = #lines - 1
				add_region(entry, {
					kind = "block",
					start_row = start_row,
					start_col = 0,
					end_row = end_row,
					end_col = #lines[end_row + 1],
					baseline = baseline,
					single_line = single_line,
					placeholder = M.EMPTY,
					border = { border, border_hl },
				})
				table.insert(lines, "")
			end
			goto continue
		end

		local text = display_text(raw_value, entry.date_format, "datetime")
		if text == "" then
			text = M.EMPTY
		end

		if section_style == "pill" then
			table.insert(lines, "")
			table.insert(lines, "")
			table.insert(extmarks, {
				line = #lines - 1,
				col = 0,
				opts = { virt_text = pill_line_chunks(heading, text, border, border_hl), virt_text_pos = "overlay" },
			})
			table.insert(lines, "")
		elseif section_style == "heading" then
			local line = heading .. ": " .. text
			table.insert(lines, "")
			table.insert(lines, line)
			table.insert(extmarks, { line = #lines - 1, col = 0, opts = { hl_group = "Title", end_col = #line } })
			table.insert(lines, "")
		else
			table.insert(lines, "## " .. heading)
			table.insert(extmarks, border_mark(#lines - 1, border, border_hl))
			table.insert(lines, "")
			table.insert(extmarks, border_mark(#lines - 1, border, border_hl))
			for _, body_line in ipairs(vim.split(text, "\n", { plain = true })) do
				table.insert(lines, body_line)
				table.insert(extmarks, border_mark(#lines - 1, border, border_hl))
			end
			table.insert(lines, "")
		end

		::continue::
	end

	return { lines = lines, extmarks = extmarks, regions = regions, sections = sections }
end

---@param buf integer
---@param ns integer
---@param extmarks { line: integer, col: integer, opts: table }[]
function M.apply_extmarks(buf, ns, extmarks)
	for _, mark in ipairs(extmarks) do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.line, mark.col, mark.opts)
	end
end

return M
