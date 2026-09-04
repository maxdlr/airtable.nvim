local config = require("airtable.config")
local view = require("airtable.view")
local api = require("airtable.api")
local format_field = api.format_field

local M = {}

local entry_display = require("telescope.pickers.entry_display")
local previewers = require("telescope.previewers")

---Default highlight groups by section position, used when a `result_line` entry omits
---`hl`: 1st section stands out as the identifier, 2nd as a secondary comment, everything
---after that as a plain comment.
local DEFAULT_HL_BY_POSITION = {
	"TelescopeResultsIdentifier",
	"TelescopeResultsSpecialComment",
}
local DEFAULT_HL_FALLBACK = "TelescopeResultsComment"

---Cache of hex color -> generated highlight group name, so repeated colors (or repeated
---picker invocations) don't keep redefining the same highlight group.
local hex_hl_cache = {}

---Resolves a `result_line` section's `hl` to a highlight group name. `hl` accepts:
---  - nil: falls back to a sensible default based on the section's position (see
---    `DEFAULT_HL_BY_POSITION`).
---  - a highlight group name or hex color like "#FFFFFF", used unconditionally.
---  - a list of `{ value = ..., color = ... }` rules: the first rule whose `value`
---    matches `text` exactly wins; if none match, falls back to the position-based
---    default (same as `hl == nil`).
---@param hl string|{value: string, color: string}[]|nil
---@param position integer 1-based index of this section within its result_line
---@param text string? The section's actual displayed text, needed to evaluate conditional rules
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

---Builds the plain-text ordinal string (used for fuzzy matching) from all `result_line`
---sections, so search isn't limited to just the first section.
---@param record AirtableRecord
---@param result_line AirtableResultSection[]
---@return string
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

-- Prefix that switches the picker from "fuzzy match the visible row" to "substring
-- search across every configured `buffer.fields` value" (title, description, and any
-- other field — not just what's shown in the result line). Chosen to look like a
-- deliberate flag/marker rather than something a real query would start with.
local DEEP_SEARCH_PREFIX = "--"

---Concatenates every `buffer.fields` value for `record` into one lowercased blob, used
---for deep/full-content search. Built once per record (cached on the entry) rather than
---per keystroke, since the underlying field values never change during a picker session.
---@param record AirtableRecord
---@return string
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

---Builds a sorter that fuzzy-matches the visible row by default, or does a plain
---substring search across every `buffer.fields` value when the prompt starts with
---`DEEP_SEARCH_PREFIX` (e.g. typing "--feature-flag-xyz" searches descriptions/notes/etc,
---not just what's shown in the result line) — entirely local, no extra API calls.
---
---Patches the *actual* configured sorter's `scoring_function` in place, rather than
---wrapping it in a new `Sorter` object — some sorters (notably telescope-fzf-native) are
---stateful and rely on `init`/`start`/`destroy` lifecycle hooks being called by Telescope
---on the exact same object it manages; delegating to a nested sorter instance skips that
---lifecycle and crashes (e.g. fzf-native's internal `slab` never gets allocated).
---@return table sorter
local function make_sorter()
	local sorter = require("telescope.config").values.generic_sorter({})
	local original_scoring_function = sorter.scoring_function

	sorter.scoring_function = function(self, prompt, ordinal, entry, ...)
		if prompt:sub(1, #DEEP_SEARCH_PREFIX) == DEEP_SEARCH_PREFIX then
			local query = vim.trim(prompt:sub(#DEEP_SEARCH_PREFIX + 1))
			if query == "" then
				return 1
			end -- prefix alone with no query yet: show everything

			entry._deep_search_text = entry._deep_search_text or deep_search_text(entry.value)
			if entry._deep_search_text:find(query:lower(), 1, true) then
				return 1 -- any positive score keeps the entry; exact ranking doesn't matter here
			end
			return -1 -- negative score filters the entry out
		end

		return original_scoring_function(self, prompt, ordinal, entry, ...)
	end

	return sorter
end

---Builds the segmented `display` function for a record entry: an optional leading icon
---resolved from `picker.result_line_prefix` (advanced/optional, see config docs), followed
---by one section per `result_line` entry, separated by " │ ". Missing fields render as "—".
---All sections but the last auto-size to their content; the last fills remaining width.
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
			-- Explicit `date_format` always wins; otherwise, auto-detect an ISO-8601
			-- timestamp and default to "date" (date-only) in the picker row — the full
			-- record buffer defaults to "datetime" instead (see view.lua).
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

---Builds the set of `buffer.fields` keys whose Airtable field name is already shown in
---`result_line`, so the preview doesn't repeat what's already visible in the result row.
---@param result_line AirtableResultSection[]
---@return table<string, boolean>
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

---Builds a previewer that renders a record's `buffer.fields` (minus whatever `result_line`
---already shows) as markdown, using only the data already fetched by the picker — no
---extra request per preview. Fields absent from the record (e.g. not present on this
---particular record) are silently omitted rather than shown as empty.
---@param result_line AirtableResultSection[]
---@return table
local function make_previewer(result_line)
	local exclude = buffer_keys_shown_in_result_line(result_line)

	return previewers.new_buffer_previewer({
		title = "Preview",
		define_preview = function(self, entry)
			local lines, extmarks = view.render_buffer(entry.value, { exclude = exclude, skip_missing = true })
			vim.bo[self.state.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
			-- Clear any extmarks from a previous preview render before applying the new ones
			-- (the previewer buffer is reused across selections, not recreated each time).
			vim.api.nvim_buf_clear_namespace(self.state.bufnr, view.NAMESPACE, 0, -1)
			view.apply_extmarks(self.state.bufnr, extmarks)
			vim.bo[self.state.bufnr].filetype = "markdown"
			-- Not modifiable/buftype nofile: this is a read-only preview of already-fetched
			-- data, and linters/LSP that guard on `vim.bo.modifiable` (as this config's own
			-- nvim-lint autocmd does) should skip it rather than lint a scratch buffer.
			vim.bo[self.state.bufnr].modifiable = false
			vim.bo[self.state.bufnr].buftype = "nofile"
		end,
	})
end

---Builds the Telescope finder for a list of records, matching `picker`'s display config.
---@param records AirtableRecord[]
---@param picker AirtablePicker
---@return table finder
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

---Opens a Telescope picker for `picker` immediately (with a "Loading…" prompt title and no
---results yet), then calls `fetch_records(callback)` to fetch the actual data and refreshes
---the picker in place once it arrives — so the UI shows up right away instead of the whole
---command appearing to hang while the network request is in flight.
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
			-- Nothing to browse: close the (empty) picker and surface the error instead of
			-- leaving a permanently-loading, unusable prompt open.
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
