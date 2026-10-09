local config = require("airtable.config")
local view = require("airtable.view")
local api = require("airtable.api")
local format_field = api.format_field

local M = {}

-- Default hl by section position when a result_line entry omits `hl`.
local DEFAULT_HL_BY_POSITION = {
	"SnacksPickerIdentifier",
	"SnacksPickerSpecial",
}
local DEFAULT_HL_FALLBACK = "SnacksPickerComment"

-- hex color -> generated highlight group name, so repeated colors don't redefine the group.
local hex_hl_cache = {}

-- hl accepts: nil (position-based default), a group name/hex color, or a list of
-- { value, color } rules (first exact match on `text` wins, else the default).
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

-- Ordinal for fuzzy matching, built from all result_line sections (not just the first).
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

-- Prefix that switches from "fuzzy match the visible row" to "substring search across
-- every buffer.fields value" (description, notes, etc).
local DEEP_SEARCH_PREFIX = "--"

-- Cached per-record (on the item) since field values don't change during a session.
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

-- Patches the *actual* matcher instance's `match` method in place rather than wrapping
-- it: Snacks drives matching through this one object per picker (same reasoning as the
-- old Telescope sorter patch — replacing the instance instead of patching it in place
-- would desync it from whatever internal state/lifecycle Snacks manages on it).
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

-- Leading icon (from result_line_prefix) + one section per result_line entry, separated
-- by " • ". Missing fields render as "—".
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
			-- explicit date_format wins; else auto-detect, default to date-only in picker rows
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

-- buffer.fields keys already shown in result_line, so the preview doesn't repeat them.
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

-- Renders buffer.fields (minus what result_line already shows) using data already
-- fetched by the picker — no extra request per preview.
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

-- Opens the picker immediately with a "Loading…" title; Snacks' async finder populates
-- items as fetch_records's callback fires, so the UI shows up right away instead of the
-- whole command appearing to hang while the network request is in flight.
---@param picker AirtablePicker
---@param fetch_records fun(callback: fun(records: AirtableRecord[]?, err: AirtableError?))
function M.pick(picker, fetch_records)
	local notify = require("airtable.notify").notify
	local snacks_picker ---@type snacks.Picker?

	snacks_picker = Snacks.picker.pick({
		title = picker.name .. " (loading…)",
		format = function(item)
			return make_display(item.record, picker)
		end,
		preview = make_previewer(picker.result_line),
		finder = function(_, _)
			return function(cb)
				-- Bridges fetch_records's async callback (network I/O via plenary.curl,
				-- itself vim.schedule_wrap'd) into Snacks' coroutine-based finder: capture
				-- the running async task, suspend it, and resume it once the real callback
				-- fires — same pattern Snacks' own proc.lua source uses for libuv callbacks.
				-- A plain vim.wait busy-loop here would be unsafe: this function runs inside
				-- a coroutine driven by Snacks' own scheduler, and re-entering the event loop
				-- from inside it isn't a supported bridge point.
				--
				-- fetch_records's callback could in principle fire synchronously (before
				-- suspend() below ever runs) — resume() is a no-op if called before the
				-- matching suspend(), which would permanently stall the finder. Guard
				-- against that ordering with a flag instead of assuming async timing.
				local async = require("snacks.picker.util.async").running()
				local done = false

				fetch_records(function(records, err)
					if err then
						notify(err.category, err.message, vim.log.levels.ERROR)
					elseif #records == 0 then
						notify("No Records", string.format('no records for picker "%s"', picker.name), vim.log.levels.INFO)
					else
						for _, record in ipairs(records) do
							cb(make_item(record, picker))
						end
						if snacks_picker then
							snacks_picker.title = picker.name
							snacks_picker:update_titles()
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
			p:close()
			if item then
				view.open(item.record.id)
			end
		end,
	})

	patch_matcher_for_deep_search(snacks_picker)
end

return M
