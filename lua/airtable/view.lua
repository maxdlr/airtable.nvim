local config = require("airtable.config")
local notify = require("airtable.notify").notify
local api = require("airtable.api")
local format_field = api.format_field
local style = require("airtable.style")
local colors = require("airtable.colors")
local bubble = require("airtable.bubble")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("airtable_view")

-- Plain buffer character (not a sign/statuscolumn) so it renders the same in a real
-- buffer and in Telescope's previewer.
local LEFT_BORDER = "▌"
local LEFT_BORDER_HL = "Comment"

---@param heading string
---@param text string
---@return { [1]: string, [2]: string }[]
local function pill_line_chunks(heading, text)
	if text == "_Empty._" then
		return { { heading .. ": ", "Title" }, { text, "Comment" } }
	end

	local ok, chunks = pcall(function()
		local hex = colors.color_for_value(text)
		local pill_chunks = bubble.make_bubble(text, hex)
		local result = { { heading .. " ", "Title" } }
		vim.list_extend(result, pill_chunks)
		return result
	end)
	if ok then
		return chunks
	end
	return { { heading .. ": " .. text, "Normal" } }
end

-- Builds markdown lines + extmark specs for a record from buffer.fields, in config
-- order (the "title" key becomes the H1 heading regardless of position).
-- opts.exclude: keys to omit (already shown elsewhere, e.g. a picker's result_line).
-- opts.skip_missing: omit absent fields instead of rendering "_Empty._" (for previews
-- built from list data, where absence just means "not fetched").
---@param record AirtableRecord
---@return string[] lines
---@return { line: integer, col: integer, opts: table }[] extmarks
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
			-- explicit date_format wins; else auto-detect ISO-8601, default to full datetime here
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

		if section_style == "pill" then
			table.insert(lines, "")
			local line_idx = #lines
			table.insert(lines, "")
			table.insert(extmarks, {
				line = line_idx,
				col = 0,
				opts = { virt_text = pill_line_chunks(heading, text), virt_text_pos = "overlay" },
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
			vim.list_extend(lines, { "## " .. heading, "" })
			for _, body_line in ipairs(vim.split(text, "\n", { plain = true })) do
				table.insert(lines, body_line)
				table.insert(extmarks, {
					line = #lines - 1,
					col = 0,
					opts = {
						virt_text = { { LEFT_BORDER, LEFT_BORDER_HL } },
						virt_text_pos = "inline",
					},
				})
			end
			table.insert(lines, "")
		end

		::continue::
	end

	return lines, extmarks
end
M.render_buffer = render_buffer

-- Each extmark is individually pcall-guarded so one bad spec can't break the rest.
function M.apply_extmarks(buf, extmarks)
	for _, mark in ipairs(extmarks) do
		pcall(vim.api.nvim_buf_set_extmark, buf, M.NAMESPACE, mark.line, mark.col, mark.opts)
	end
end

local function refresh_buffer(buf, record)
	local lines, extmarks = render_buffer(record)
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_clear_namespace(buf, M.NAMESPACE, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	M.apply_extmarks(buf, extmarks)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local MENU_SEPARATOR = false

-- Built as a real Telescope picker (not vim.ui.select) so the separator between
-- built-in and edit actions renders consistently (dimmed, unselectable) regardless of
-- the user's vim.ui.select backend.
---@param buf integer
---@param record_id string
local function open_context_menu(buf, record_id)
	local editable = config.options.buffer.editable or {}

	---@type { [1]: string, [2]: string|function|false }[]
	local menu_items = {
		{ "Open in browser", "open_in_browser" },
		{ "Browse comments", "browse_comments" },
		{ "Copy record URL", "copy_url" },
	}

	if #editable > 0 then
		table.insert(menu_items, { "───────────────", MENU_SEPARATOR })
		for _, entry in ipairs(editable) do
			table.insert(menu_items, { entry.name or ("Edit " .. entry.field), entry })
		end
	end

	local function run_action(action)
		if action == "open_in_browser" then
			api.record_url(record_id, function(url, err)
				if err then
					notify(err.category, err.message, vim.log.levels.ERROR)
					return
				end
				vim.ui.open(url)
			end)
		elseif action == "browse_comments" then
			require("airtable.comments").pick(record_id)
		elseif action == "copy_url" then
			api.record_url(record_id, function(url, err)
				if err then
					notify(err.category, err.message, vim.log.levels.ERROR)
					return
				end
				vim.fn.setreg("+", url)
				notify("Copied", "record URL copied to clipboard", vim.log.levels.INFO)
			end)
		elseif type(action) == "table" then
			local entry = action
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
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local themes = require("telescope.themes")
	local telescope_config = require("telescope.config")

	pickers
		.new(
			themes.get_dropdown({
				winblend = 5,
				layout_config = {
					prompt_position = "top",
					width = function(_, max_columns, _) return math.max(40, math.floor(max_columns * 0.25)) end,
					height = #menu_items + 4,
				},
			}),
			{
				prompt_title = "Airtable record",
				finder = finders.new_table({
					results = menu_items,
					entry_maker = function(item)
						local is_separator = item[2] == MENU_SEPARATOR
						return {
							value = item,
							-- empty ordinal: separator never matches search input
							ordinal = is_separator and "" or item[1],
							display = function(entry)
								local hl = is_separator and "Comment" or "Normal"
								return entry.value[1], { { { 0, #entry.value[1] }, hl } }
							end,
						}
					end,
				}),
				sorter = telescope_config.values.generic_sorter({}),
				attach_mappings = function(prompt_bufnr, map)
					-- Skip separator rows when moving the selection so they can't be landed on.
					local function skip_separators(move)
						return function()
							move(prompt_bufnr)
							local guard = 0
							while action_state.get_selected_entry().value[2] == MENU_SEPARATOR and guard < #menu_items do
								move(prompt_bufnr)
								guard = guard + 1
							end
						end
					end
					map({ "i", "n" }, "<Down>", skip_separators(actions.move_selection_next))
					map({ "i", "n" }, "<C-n>", skip_separators(actions.move_selection_next))
					map({ "i", "n" }, "<Up>", skip_separators(actions.move_selection_previous))
					map({ "i", "n" }, "<C-p>", skip_separators(actions.move_selection_previous))

					actions.select_default:replace(function()
						local selection = action_state.get_selected_entry()
						local action = selection.value[2]
						if action == MENU_SEPARATOR then return end
						actions.close(prompt_bufnr)
						run_action(action)
					end)
					return true
				end,
			}
		)
		:find()
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

-- Closes any existing buffer for this record first, since nvim_buf_set_name errors
-- with "buffer already exists" when reopening the same record.
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

		local buf_name = "airtable://" .. record.id
		local existing_buf = vim.fn.bufnr(buf_name)
		if existing_buf ~= -1 then
			pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "markdown"
		vim.api.nvim_buf_set_name(buf, buf_name)
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

		vim.api.nvim_set_current_buf(buf)
	end)
end

return M
