local config = require("airtable.config")
local notify = require("airtable.notify").notify
local api = require("airtable.api")
local format_field = api.format_field
local style = require("airtable.style")
local colors = require("airtable.colors")
local bubble = require("airtable.bubble")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("airtable_view")

local last_record_id = nil

---@return string?
function M.last_record_id()
	return last_record_id
end

---@param key string
---@return AirtableBufferField?
function M.find_buffer_field(key)
	for _, entry in ipairs(config.options.buffer.fields) do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

local DEFAULT_LEFT_BORDER = "▌ "
local LEFT_BORDER_HL = "Comment"
local DEFAULT_EDITABLE_BORDER_COLOR = "#FFA500"

local function left_border()
	local style = config.options.buffer.style
	return (style and style.section_border_character) or DEFAULT_LEFT_BORDER
end

---@param key string
---@return boolean
local function is_editable_key(key)
	local field_entry = M.find_buffer_field(key)
	if not field_entry then
		return false
	end
	for _, entry in ipairs(config.options.buffer.editable or {}) do
		if entry.field == field_entry.field then
			return true
		end
	end
	return false
end

---@param key string
---@return string highlight_group
local function left_border_hl(key)
	if not is_editable_key(key) then
		return LEFT_BORDER_HL
	end
	local style = config.options.buffer.style
	local color = (style and style.editable_section_border_color) or DEFAULT_EDITABLE_BORDER_COLOR
	return colors.create_foreground_highlight(color)
end

---@param heading string
---@param text string
---@param border string
---@param border_hl string
---@return { [1]: string, [2]: string }[]
local function pill_line_chunks(heading, text, border, border_hl)
	if text == "_Empty._" then
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

---@param record AirtableRecord
---@return string[] lines
---@return { line: integer, col: integer, opts: table }[] extmarks
---@return table<integer, string> line_to_key
local function render_buffer(record, opts)
	opts = opts or {}
	local exclude = opts.exclude or {}
	local fields = config.options.buffer.fields

	local title = ""
	for _, entry in ipairs(fields) do
		if entry.key == "title" then
			title = format_field(record.fields[entry.field])
			if entry.date_format then
				title = api.format_date(title, entry.date_format)
			end
			break
		end
	end
	if title == "" then
		title = "(untitled)"
	end

	local lines = { "# " .. title, "" }
	local extmarks = {}
	local line_to_key = {}

	for _, entry in ipairs(fields) do
		local key = entry.key
		local field_name = entry.field
		if key == "title" or exclude[key] then
			goto continue
		end

		local raw_value = record.fields[field_name]
		if raw_value == nil and opts.skip_missing then
			goto continue
		end

		local text = format_field(raw_value)
		if text ~= "" then
			local mode = entry.date_format or (api.looks_like_date(text) and "datetime" or nil)
			if mode then
				text = api.format_date(text, mode)
			end
		end
		if text == "" then
			text = "_Empty._"
		end
		local heading = key:sub(1, 1):upper() .. key:sub(2)
		local section_style = style.classify(key)
		local section_start_line = #lines

		if section_style == "pill" then
			table.insert(lines, "")
			local line_idx = #lines
			table.insert(lines, "")
			table.insert(extmarks, {
				line = line_idx,
				col = 0,
				opts = {
					virt_text = pill_line_chunks(heading, text, left_border(), left_border_hl(key)),
					virt_text_pos = "overlay",
				},
			})
			table.insert(lines, "")
		elseif section_style == "heading" then
			table.insert(lines, "")
			table.insert(lines, heading .. ": " .. text)
			table.insert(extmarks, {
				line = #lines - 1,
				col = 0,
				opts = { hl_group = "Title", end_col = #(heading .. ": " .. text) },
			})
			table.insert(lines, "")
		else
			local border = left_border()
			local border_hl = left_border_hl(key)
			table.insert(lines, "## " .. heading)
			table.insert(extmarks, {
				line = #lines - 1,
				col = 0,
				opts = { virt_text = { { border, border_hl } }, virt_text_pos = "inline" },
			})
			table.insert(lines, "")
			table.insert(extmarks, {
				line = #lines - 1,
				col = 0,
				opts = { virt_text = { { border, border_hl } }, virt_text_pos = "inline" },
			})
			for _, body_line in ipairs(vim.split(text, "\n", { plain = true })) do
				table.insert(lines, body_line)
				table.insert(extmarks, {
					line = #lines - 1,
					col = 0,
					opts = {
						virt_text = { { border, border_hl } },
						virt_text_pos = "inline",
					},
				})
			end
			table.insert(lines, "")
		end

		for line_idx = section_start_line, #lines - 1 do
			line_to_key[line_idx] = key
		end

		::continue::
	end

	return lines, extmarks, line_to_key
end
M.render_buffer = render_buffer

function M.apply_extmarks(buf, extmarks)
	for _, mark in ipairs(extmarks) do
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NAMESPACE, mark.line, mark.col, mark.opts)
	end
end

local buf_line_to_key = {} ---@type table<integer, table<integer, string>>

local function refresh_buffer(buf, record)
	local lines, extmarks, line_to_key = render_buffer(record)
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_clear_namespace(buf, M.NAMESPACE, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	M.apply_extmarks(buf, extmarks)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	buf_line_to_key[buf] = line_to_key
end

---@param buf integer
---@param record_id string
---@param entry AirtableEditableField
local function start_edit(buf, record_id, entry)
	local edit = require("airtable.edit")
	local on_updated = function(updated_record)
		if vim.api.nvim_buf_is_valid(buf) then
			refresh_buffer(buf, updated_record)
		end
	end

	if entry.type == "select" then
		edit.edit_select(record_id, entry.field, on_updated)
	elseif entry.type == "text" then
		api.get_recordById(record_id, function(record, err)
			if err then
				notify(err.category, err.message, vim.log.levels.ERROR)
				return
			end
			local current_value = format_field(record.fields[entry.field])
			edit.edit_text(record_id, entry.field, current_value, on_updated)
		end)
	end
end

---@param buf integer
---@param record_id string
local function open_context_menu(buf, record_id)
	local editable = config.options.buffer.editable or {}
	local honcho = require("honcho")

	local commands = {
		{
			label = "Open in browser",
			action = function()
				api.record_url(record_id, function(url, err)
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
						return
					end
					vim.ui.open(url)
				end)
			end,
		},
		{
			label = "Browse comments",
			action = function()
				require("airtable.comments").pick(record_id)
			end,
		},
		{
			label = "Copy record URL",
			action = function()
				api.record_url(record_id, function(url, err)
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
						return
					end
					vim.fn.setreg("+", url)
					notify("Copied", "record URL copied to clipboard", vim.log.levels.INFO)
				end)
			end,
		},
		{
			label = "Refresh",
			action = function()
				api.get_recordById(record_id, function(record, err)
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
						return
					end
					if vim.api.nvim_buf_is_valid(buf) then
						refresh_buffer(buf, record)
					end
					notify("Refreshed", "record reloaded from Airtable", vim.log.levels.INFO)
				end)
			end,
		},
	}

	if #editable > 0 then
		table.insert(commands, { label = "───────────────", action = false })
		for _, entry in ipairs(editable) do
			table.insert(commands, {
				label = entry.name or (" " .. entry.field),
				action = function()
					start_edit(buf, record_id, entry)
				end,
			})
		end
	end

	honcho.honcho_picker("Airtable record", commands)()
end

---@return string?
local function url_under_cursor()
	local ok, result = pcall(function()
		local line = vim.api.nvim_get_current_line()
		local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
		for start_col, url in line:gmatch("()(https?://[^%s%)%]>\"']+)") do
			local end_col = start_col + #url - 1
			if cursor_col >= start_col - 1 and cursor_col <= end_col - 1 then
				return url
			end
		end
		return nil
	end)
	if ok then
		return result
	end
	return nil
end

---@param record_id string
function M.open(record_id)
	notify("Loading", "fetching record...", vim.log.levels.INFO)
	api.get_recordById(record_id, function(record, err)
		if err then
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		if not record then
			notify("No Record", string.format('no record found for id "%s"', record_id), vim.log.levels.INFO)
			return
		end

		local record_identifier = config.options.buffer.name.field
		local identifier_value = record_identifier and format_field(record.fields[record_identifier]) or record.id
		last_record_id = record.id

		local buf_name = "airtable://" .. (identifier_value or record.id)
		local existing_buf = vim.fn.bufnr(buf_name)
		if existing_buf ~= -1 then
			pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "markdown"
		vim.api.nvim_buf_set_name(buf, "Airtable  " .. buf_name)
		refresh_buffer(buf, record)

		vim.keymap.set("n", "<CR>", function()
			open_context_menu(buf, record.id)
		end, { buffer = buf, desc = "Airtable record actions" })

		vim.keymap.set("n", "o", function()
			local url = url_under_cursor()
			if not url then
				notify("No URL", "no URL under cursor", vim.log.levels.INFO)
				return
			end
			vim.ui.open(url)
		end, { buffer = buf, desc = "Open URL under cursor" })

		vim.keymap.set("n", "c", function()
			local url = url_under_cursor()
			if not url then
				notify("No URL", "no URL under cursor", vim.log.levels.INFO)
				return
			end
			vim.fn.setreg("+", url)
			notify("Copied", "URL copied to clipboard", vim.log.levels.INFO)
		end, { buffer = buf, desc = "Copy URL under cursor" })

		vim.keymap.set("n", "e", function()
			local line = vim.api.nvim_win_get_cursor(0)[1] - 1
			local key = (buf_line_to_key[buf] or {})[line]
			if not key then
				notify("Not Editable", "no field under cursor", vim.log.levels.INFO)
				return
			end

			local entry
			for _, e in ipairs(config.options.buffer.editable or {}) do
				local field_entry = M.find_buffer_field(key)
				if field_entry and e.field == field_entry.field then
					entry = e
					break
				end
			end

			if not entry then
				notify(
					"Not Editable",
					string.format('add "%s" to buffer.editable to edit it', key),
					vim.log.levels.INFO
				)
				return
			end

			start_edit(buf, record.id, entry)
		end, { buffer = buf, desc = "Edit field under cursor" })

		vim.api.nvim_set_current_buf(buf)
	end)
end

return M
