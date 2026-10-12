local config = require("airtable.config")
local view = require("airtable.view")
local api = require("airtable.api")
local format_field = api.format_field

local M = {}

local DEFAULT_HL_BY_POSITION = {
	"SnacksPickerIdentifier",
	"SnacksPickerSpecial",
}
local DEFAULT_HL_FALLBACK = "SnacksPickerComment"

local hex_hl_cache = {}

---@param hl string|{value: string, color: string}[]|nil
---@param position integer
---@param text string?
---@return string
local function resolve_hl(hl, position, text)
	if hl == nil then
		return DEFAULT_HL_BY_POSITION[position] or DEFAULT_HL_FALLBACK
	end

	if type(hl) == "table" then
		for _, rule in ipairs(hl) do
			if rule.value == text then
				return resolve_hl(rule.color, position, text)
			end
		end
		return DEFAULT_HL_BY_POSITION[position] or DEFAULT_HL_FALLBACK
	end

	if not hl:match("^#%x%x%x%x%x%x$") then
		return hl
	end

	local cached = hex_hl_cache[hl]
	if cached then
		return cached
	end

	local group = "AirtableColor" .. hl:sub(2)
	vim.api.nvim_set_hl(0, group, { fg = hl })
	hex_hl_cache[hl] = group
	return group
end

local function ordinal_text(record, result_line)
	local parts = {}
	for _, section in ipairs(result_line) do
		local text = format_field(record.fields[section.field])
		if text ~= "" then
			table.insert(parts, text)
		end
	end
	return table.concat(parts, " ")
end

local DEEP_SEARCH_PREFIX = "--"

local function deep_search_text(record)
	local parts = {}
	for _, entry in ipairs(config.options.buffer.fields) do
		local text = format_field(record.fields[entry.field])
		if text ~= "" then
			table.insert(parts, text)
		end
	end
	return table.concat(parts, " "):lower()
end

-- Patches the matcher instance's match method in place instead of wrapping it, since
-- Snacks drives matching through this exact object per picker.
---@param picker snacks.Picker
local function patch_matcher_for_deep_search(picker)
	local matcher = picker.matcher
	local original_match = matcher.match
	local DEFAULT_SCORE = require("snacks.picker.core.matcher").DEFAULT_SCORE

	matcher.match = function(self, item)
		local pattern = self.pattern or ""
		if pattern:sub(1, #DEEP_SEARCH_PREFIX) == DEEP_SEARCH_PREFIX then
			local query = vim.trim(pattern:sub(#DEEP_SEARCH_PREFIX + 1))
			if query == "" then
				return DEFAULT_SCORE
			end

			item._deep_search_text = item._deep_search_text or deep_search_text(item.record)
			if item._deep_search_text:find(query:lower(), 1, true) then
				return DEFAULT_SCORE
			end
			return 0
		end

		return original_match(self, item)
	end
end

---@param record AirtableRecord
---@param picker AirtablePicker
---@return snacks.picker.Highlight[]
local function make_display(record, picker)
	local sections = {}

	local icon_spec = config.resolve_prefix_icon(record, picker)
	if icon_spec ~= "" then
		if type(icon_spec) == "table" then
			table.insert(sections, { icon_spec.icon, resolve_hl(icon_spec.color or "Normal", 0) })
		else
			table.insert(sections, { icon_spec, "Normal" })
		end
	end

	for i, section in ipairs(picker.result_line) do
		local text = format_field(record.fields[section.field])
		if text ~= "" then
			local mode = section.date_format or (api.looks_like_date(text) and "date" or nil)
			if mode then
				text = api.format_date(text, mode)
			end
		end
		if text == "" then
			text = "—"
		end
		table.insert(sections, { text, resolve_hl(section.hl, i, text) })
	end

	local chunks = {}
	for i, section in ipairs(sections) do
		if i > 1 then
			table.insert(chunks, { " • ", "Comment" })
		end
		table.insert(chunks, { section[1], section[2] })
	end
	return chunks
end

local function buffer_keys_shown_in_result_line(result_line)
	local shown_field_names = {}
	for _, section in ipairs(result_line) do
		shown_field_names[section.field] = true
	end

	local exclude = {}
	for _, entry in ipairs(config.options.buffer.fields) do
		if shown_field_names[entry.field] then
			exclude[entry.key] = true
		end
	end
	return exclude
end

---@param result_line AirtableResultSection[]
---@return fun(ctx: snacks.picker.preview.ctx)
local function make_previewer(result_line)
	local exclude = buffer_keys_shown_in_result_line(result_line)

	return function(ctx)
		ctx.preview:reset()
		local lines, extmarks = view.render_buffer(ctx.item.record, { exclude = exclude, skip_missing = true })
		ctx.preview:set_lines(lines)
		ctx.preview:set_title("Preview")
		vim.bo[ctx.buf].filetype = "markdown"
		view.apply_extmarks(ctx.buf, extmarks)
	end
end

---@param record AirtableRecord
---@param picker AirtablePicker
---@return snacks.picker.Item
local function make_item(record, picker)
	return {
		text = ordinal_text(record, picker.result_line),
		record = record,
	}
end

-- "Select status" only appears if buffer.editable has a select-type entry for the
-- field mapped to the "status" key.
---@return AirtableEditableField?
local function status_editable_entry()
	local status_field = view.find_buffer_field("status")
	if not status_field then
		return nil
	end
	for _, entry in ipairs(config.options.buffer.editable or {}) do
		if entry.field == status_field.field and entry.type == "select" then
			return entry
		end
	end
	return nil
end

---@param snacks_picker snacks.Picker
---@param item snacks.picker.Item
local function apply_updated_record(snacks_picker, item, updated_record)
	item.record = updated_record
	snacks_picker.list:update({ force = true })
end

-- All actions except opening the record buffer keep the list picker open.
---@param snacks_picker snacks.Picker
---@param item snacks.picker.Item
local function open_record_action_menu(snacks_picker, item)
	local record = item.record
	local notify = require("airtable.notify").notify
	local honcho = require("honcho")

	local commands = {
		{
			label = "Open record in buffer",
			action = function()
				snacks_picker:close()
				view.open(record.id)
			end,
		},
		{
			label = "Open record in browser",
			action = function()
				api.record_url(record.id, function(url, err)
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
						return
					end
					vim.ui.open(url)
				end)
			end,
		},
		{
			label = "Copy URL",
			action = function()
				api.record_url(record.id, function(url, err)
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
						return
					end
					vim.fn.setreg("+", url)
					notify("Copied", "record URL copied to clipboard", vim.log.levels.INFO)
				end)
			end,
		},
	}

	local status_entry = status_editable_entry()
	if status_entry then
		table.insert(commands, {
			label = "Select status",
			action = function()
				require("airtable.edit").edit_select(record.id, status_entry.field, function(updated_record)
					apply_updated_record(snacks_picker, item, updated_record)
				end)
			end,
		})
	end

	honcho.honcho_picker("Record actions", commands)()
end

---@return { close: fun() }
local function show_loading_modal()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"

	local width, height = 12, 3
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		focusable = false,
		zindex = 250,
	})
	vim.wo[win].winhighlight = "NormalFloat:NormalFloat"

	local timer = assert(vim.uv.new_timer())
	timer:start(0, 80, function()
		vim.schedule(function()
			if not vim.api.nvim_win_is_valid(win) then
				timer:stop()
				timer:close()
				return
			end
			local spinner = Snacks.util.spinner()
			local line = string.rep(" ", math.max(0, math.floor((width - 2 - vim.fn.strdisplaywidth(spinner)) / 2)))
				.. spinner
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", line, "" })
		end)
	end)

	local closed = false
	return {
		close = function()
			if closed then
				return
			end
			closed = true
			timer:stop()
			timer:close()
			-- close() may run from fetch_records's callback in a fast-event context.
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
			end)
		end,
	}
end

---@param picker AirtablePicker
---@param fetch_records fun(callback: fun(records: AirtableRecord[]?, err: AirtableError?))
function M.pick(picker, fetch_records)
	local notify = require("airtable.notify").notify
	local snacks_picker ---@type snacks.Picker?
	local loading_modal = show_loading_modal()

	snacks_picker = Snacks.picker.pick({
		title = picker.name,
		show_empty = false,
		format = function(item)
			return make_display(item.record, picker)
		end,
		preview = make_previewer(picker.result_line),
		finder = function(_, _)
			return function(cb)
				-- Bridges fetch_records's async callback into Snacks' coroutine-based
				-- finder via suspend/resume, same pattern as Snacks' own proc.lua source.
				-- Guarded with `done` since the callback could fire before suspend() runs.
				local async = require("snacks.picker.util.async").running()
				local done = false

				fetch_records(function(records, err)
					loading_modal.close()
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
					elseif #records == 0 then
						notify("No Records", string.format('no records for picker "%s"', picker.name), vim.log.levels.INFO)
					else
						for _, record in ipairs(records) do
							cb(make_item(record, picker))
						end
					end
					done = true
					if async then
						async:resume()
					end
				end)

				if async and not done then
					async:suspend()
				end
			end
		end,
		confirm = function(p, item)
			if item then
				open_record_action_menu(p, item)
			end
		end,
	})

	patch_matcher_for_deep_search(snacks_picker)
end

return M
