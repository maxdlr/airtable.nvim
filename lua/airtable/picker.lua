local config = require("airtable.config")
local view = require("airtable.view")
local api = require("airtable.api")
local format_field = api.format_field

local M = {}

local entry_display = require("telescope.pickers.entry_display")
local previewers = require("telescope.previewers")

-- Default hl by section position when a result_line entry omits `hl`.
local DEFAULT_HL_BY_POSITION = {
	"TelescopeResultsIdentifier",
	"TelescopeResultsSpecialComment",
}
local DEFAULT_HL_FALLBACK = "TelescopeResultsComment"

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

-- Cached per-record (on the entry) since field values don't change during a session.
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

-- Patches the *actual* configured sorter's scoring_function in place rather than
-- wrapping it in a new Sorter object: stateful sorters (e.g. telescope-fzf-native) rely
-- on init/start/destroy lifecycle hooks being called by Telescope on the exact object it
-- manages — delegating to a nested instance skips that and crashes (fzf-native's `slab`
-- never gets allocated).
---@return table sorter
local function make_sorter()
	local sorter = require("telescope.config").values.generic_sorter({})
	local original_scoring_function = sorter.scoring_function

	sorter.scoring_function = function(self, prompt, ordinal, entry, ...)
		if prompt:sub(1, #DEEP_SEARCH_PREFIX) == DEEP_SEARCH_PREFIX then
			local query = vim.trim(prompt:sub(#DEEP_SEARCH_PREFIX + 1))
			if query == "" then
				return 1
			end

			entry._deep_search_text = entry._deep_search_text or deep_search_text(entry.value)
			if entry._deep_search_text:find(query:lower(), 1, true) then
				return 1
			end
			return -1
		end

		return original_scoring_function(self, prompt, ordinal, entry, ...)
	end

	return sorter
end

-- Leading icon (from result_line_prefix) + one section per result_line entry, separated
-- by " │ ". Missing fields render as "—"; last section fills remaining width.
---@param record AirtableRecord
---@param picker AirtablePicker
---@return function
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

	local items = {}
	for i = 1, #sections do
		items[i] = i == #sections and { remaining = true } or { width = nil }
	end

	local displayer = entry_display.create({
		separator = " • ",
		items = items,
	})

	return function()
		return displayer(sections)
	end
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
local function make_previewer(result_line)
	local exclude = buffer_keys_shown_in_result_line(result_line)

	return previewers.new_buffer_previewer({
		title = "Preview",
		define_preview = function(self, entry)
			local lines, extmarks = view.render_buffer(entry.value, { exclude = exclude, skip_missing = true })
			vim.bo[self.state.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
			-- previewer buffer is reused across selections, not recreated each time
			vim.api.nvim_buf_clear_namespace(self.state.bufnr, view.NAMESPACE, 0, -1)
			view.apply_extmarks(self.state.bufnr, extmarks)
			vim.bo[self.state.bufnr].filetype = "markdown"
			vim.bo[self.state.bufnr].modifiable = false
			vim.bo[self.state.bufnr].buftype = "nofile"
		end,
	})
end

local function make_finder(records, picker)
	local finders = require("telescope.finders")
	return finders.new_table({
		results = records,
		entry_maker = function(record)
			return {
				value = record,
				display = make_display(record, picker),
				ordinal = ordinal_text(record, picker.result_line),
			}
		end,
	})
end

-- Opens the picker immediately with a "Loading…" title and no results, then refreshes
-- it in place once fetch_records's callback fires — avoids the command appearing to
-- hang while the network request is in flight.
---@param picker AirtablePicker
---@param fetch_records fun(callback: fun(records: AirtableRecord[]?, err: AirtableError?))
function M.pick(picker, fetch_records)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local notify = require("airtable.notify").notify

	local current_picker = pickers.new({}, {
		prompt_title = picker.name .. " (loading…)",
		finder = finders.new_table({ results = {} }),
		sorter = make_sorter(),
		previewer = make_previewer(picker.result_line),
		attach_mappings = function(prompt_bufnr, map)
			actions.select_default:replace(function()
				--@type AirtableRecord
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if selection then
					view.open(selection.value.id)
				end
			end)
			return true
		end,
	})
	current_picker:find()

	fetch_records(function(records, err)
		if err then
			pcall(actions.close, current_picker.prompt_bufnr)
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		if #records == 0 then
			pcall(actions.close, current_picker.prompt_bufnr)
			notify("No Records", string.format('no records for picker "%s"', picker.name), vim.log.levels.INFO)
			return
		end

		if vim.api.nvim_buf_is_valid(current_picker.prompt_bufnr) then
			pcall(function()
				if current_picker.layout.prompt.border then
					current_picker.layout.prompt.border:change_title(picker.name)
				end
			end)
			current_picker:refresh(make_finder(records, picker), { reset_prompt = false })
		end
	end)
end

return M
