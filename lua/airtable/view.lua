-- The record buffer: a markdown buffer where `type = "text"` buffer.editable fields are
-- edited in place and autosaved (see airtable.autosave), and everything else is
-- read-only (see airtable.regions for how that's enforced).

local config = require("airtable.config")
local notify = require("airtable.notify").notify
local api = require("airtable.api")
local render = require("airtable.render")
local regions = require("airtable.regions")
local autosave = require("airtable.autosave")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("airtable_view")
M.SECTION_NS = vim.api.nvim_create_namespace("airtable_sections")

local last_record_id = nil

---@type table<integer, AirtableSession>
local sessions = {}
---@type table<string, integer> record id -> buf
local buffers_by_record = {}

---@return string?
function M.last_record_id()
	return last_record_id
end

---@param buf integer
---@return AirtableSession?
function M.session(buf)
	return sessions[buf]
end

---@param session AirtableSession
local function current_cursor(session)
	if vim.api.nvim_get_current_buf() ~= session.buf then
		return nil
	end
	local pos = vim.api.nvim_win_get_cursor(0)
	return pos[1] - 1, pos[2]
end

local on_change

-- Only allow changes while the cursor is inside an editable region.
---@param session AirtableSession
local function update_gate(session)
	if session.closed or session.rendering then
		return
	end
	-- A change can reach us before its TextChanged (InsertEnter right after `o` added
	-- a line): process it first, so the regions are where the cursor expects them.
	if vim.api.nvim_buf_get_changedtick(session.buf) ~= session.tick then
		on_change(session)
	end
	local row, col = current_cursor(session)
	if not row then
		return
	end
	local inside = regions.at(session.buf, session.regions, row, col) ~= nil
	if vim.bo[session.buf].modifiable ~= inside then
		vim.bo[session.buf].modifiable = inside
	end
end

---@param session AirtableSession
local function update_name(session)
	local name_field = config.options.buffer.name and config.options.buffer.name.field
	local identifier = name_field and api.format_field(session.record.fields[name_field]) or ""
	if identifier == "" then
		identifier = session.record_id
	end
	local name = "Airtable  airtable://" .. identifier:gsub("\n", " ")
	if vim.api.nvim_buf_get_name(session.buf) == name then
		return
	end
	-- Another record (or a stale buffer) may already hold that name.
	if not pcall(vim.api.nvim_buf_set_name, session.buf, name) then
		pcall(vim.api.nvim_buf_set_name, session.buf, string.format("%s [%s]", name, session.record_id))
	end
end

---@param session AirtableSession
---@param record AirtableRecord
---@param opts { values: table<string, string>?, preserve_dirty: boolean?, keep_undo: boolean?, keep_baseline: boolean? }?
---  values: buffer text per field, overriding the record's values.
---  preserve_dirty: keep the text of fields with unsaved edits instead of the record's.
---  keep_undo: join the re-render with the previous undo step (restores after a
---    read-only violation) instead of clearing the undo history (fresh data from
---    Airtable: undoing past it would re-send stale text).
---  keep_baseline: don't reset baselines from `record` (it isn't newer data).
local function render_into(session, record, opts)
	opts = opts or {}
	local buf = session.buf
	local values = opts.values or {}
	if opts.preserve_dirty then
		for _, region in ipairs(session.regions) do
			local text = regions.text(buf, region)
			if text ~= session.baseline[region.field] then
				values[region.field] = text
			end
		end
	end

	local layout = render.layout(record, { editable = true, field_types = session.field_types, values = values })
	local row, col = current_cursor(session)

	session.rendering = true
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	if opts.keep_undo then
		vim.api.nvim_buf_call(buf, function()
			pcall(vim.cmd, "undojoin")
		end)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
	else
		-- Documented way to clear the undo history (:h clear-undo).
		local undolevels = vim.api.nvim_get_option_value("undolevels", { buf = buf })
		vim.api.nvim_set_option_value("undolevels", -1, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
		vim.api.nvim_set_option_value("undolevels", undolevels, { buf = buf })
	end

	vim.api.nvim_buf_clear_namespace(buf, M.NAMESPACE, 0, -1)
	vim.api.nvim_buf_clear_namespace(buf, M.SECTION_NS, 0, -1)
	render.apply_extmarks(buf, M.NAMESPACE, layout.extmarks)
	session.sections = {}
	for _, section in ipairs(layout.sections) do
		local mark = vim.api.nvim_buf_set_extmark(buf, M.SECTION_NS, section.row, 0, { right_gravity = false })
		table.insert(session.sections, { key = section.key, mark = mark })
	end

	session.regions = regions.attach(buf, layout.regions)
	if not opts.keep_baseline then
		session.baseline = {}
		for _, spec in ipairs(layout.regions) do
			session.baseline[spec.field] = spec.baseline
		end
	end
	session.record = record
	session.static = regions.static_text(buf, session.regions)
	regions.decorate(buf, session.regions)

	if row then
		local line_count = vim.api.nvim_buf_line_count(buf)
		row = math.min(row, line_count - 1)
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, math.min(col, #line) })
	end

	session.tick = vim.api.nvim_buf_get_changedtick(buf)
	session.line_count = vim.api.nvim_buf_line_count(buf)
	session.rendering = false
	update_gate(session)
	autosave.refresh_status(session)
end

-- Something outside the editable regions changed (or a single-line field gained a
-- line break): rebuild the static parts around the regions' current text. The user's
-- edits inside regions survive; the stray change is dropped.
---@param session AirtableSession
local function restore(session)
	if session.closed or not vim.api.nvim_buf_is_valid(session.buf) then
		return
	end
	local values = regions.values(session.buf, session.regions)
	render_into(session, session.record, { values = values, keep_undo = true, keep_baseline = true })
	notify("Read-only", "only field values can be edited, change reverted", vim.log.levels.WARN)
	autosave.changed(session)
end

---@param session AirtableSession
local function violates_structure(session)
	if regions.static_text(session.buf, session.regions) ~= session.static then
		return true
	end
	for _, region in ipairs(session.regions) do
		if region.single_line then
			local sr, _, er = regions.range(session.buf, region)
			if er > sr then
				return true
			end
		end
	end
	return false
end

-- Some legitimate edits leave the region extmarks slightly off (see regions.normalize
-- and regions.absorb). Tries each fix in turn and keeps the first one that makes the
-- static text match again; nothing is changed if none does.
---@param session AirtableSession
---@param added integer Lines added since the last good state
---@return boolean repaired
local function repair(session, added)
	local buf, regs = session.buf, session.regions
	local snapshot = regions.snapshot(buf, regs)
	local attempts = {
		function()
			regions.normalize(buf, regs)
		end,
		function()
			regions.absorb(buf, regs, session.static, added)
		end,
	}
	for _, attempt in ipairs(attempts) do
		attempt()
		if not violates_structure(session) then
			return true
		end
		regions.restore_ranges(buf, regs, snapshot)
	end
	return false
end

---@param session AirtableSession
function on_change(session)
	if session.rendering or session.closed then
		return
	end
	local tick = vim.api.nvim_buf_get_changedtick(session.buf)
	if tick == session.tick then
		return
	end
	session.tick = tick

	local buf = session.buf
	local line_count = vim.api.nvim_buf_line_count(buf)
	if violates_structure(session) and not repair(session, line_count - session.line_count) then
		vim.schedule(function()
			restore(session)
		end)
		return
	end
	session.line_count = line_count
	regions.decorate(session.buf, session.regions)
	autosave.changed(session)
end

---@param session AirtableSession
---@return string? key buffer.fields key of the section under the cursor
local function section_key_at_cursor(session)
	local row = current_cursor(session)
	if not row then
		return nil
	end
	local found
	for _, section in ipairs(session.sections or {}) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(session.buf, M.SECTION_NS, section.mark, {})
		if pos[1] and pos[1] <= row then
			found = section.key
		end
	end
	return found
end

-- Moves the cursor to the end of a field's region and starts insert mode there.
---@param session AirtableSession
---@param field string
function M.focus_field(session, field)
	for _, region in ipairs(session.regions) do
		if region.field == field then
			vim.schedule(function()
				if session.closed or vim.api.nvim_get_current_buf() ~= session.buf then
					return
				end
				local _, _, er, ec = regions.range(session.buf, region)
				vim.api.nvim_win_set_cursor(0, { er + 1, ec })
				update_gate(session)
				vim.cmd("startinsert!")
			end)
			return
		end
	end
	notify("Not Editable", string.format('"%s" can\'t be edited in the buffer', field), vim.log.levels.INFO)
end

---@param session AirtableSession
---@param entry AirtableEditableField
local function start_select(session, entry)
	require("airtable.edit").edit_select(session.record_id, entry.field, function(updated_record)
		if session.closed then
			return
		end
		local latest = updated_record
		if autosave.is_dirty(session) then
			latest = autosave.flush_sync(session) or latest
		end
		render_into(session, latest, { preserve_dirty = true })
		update_name(session)
	end)
end

---@param session AirtableSession
---@param entry AirtableEditableField
local function start_edit(session, entry)
	if entry.type == "select" then
		start_select(session, entry)
	else
		M.focus_field(session, entry.field)
	end
end

---@param session AirtableSession
local function refresh(session)
	if autosave.is_dirty(session) then
		autosave.flush_sync(session)
	end
	api.get_recordById(session.record_id, function(record, err)
		if err then
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		if session.closed then
			return
		end
		render_into(session, record, { preserve_dirty = true })
		autosave.reset_status(session)
		update_name(session)
		notify("Refreshed", "record reloaded from Airtable", vim.log.levels.INFO)
	end)
end

local function with_record_url(record_id, fn)
	api.record_url(record_id, function(url, err)
		if err then
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		fn(url)
	end)
end

---@param session AirtableSession
local function open_context_menu(session)
	local editable = config.options.buffer.editable or {}

	local commands = {
		{
			label = "Open in browser",
			action = function()
				with_record_url(session.record_id, vim.ui.open)
			end,
		},
		{
			label = "Browse comments",
			action = function()
				require("airtable.comments").pick(session.record_id)
			end,
		},
		{
			label = "Copy record URL",
			action = function()
				with_record_url(session.record_id, function(url)
					vim.fn.setreg("+", url)
					notify("Copied", "record URL copied to clipboard", vim.log.levels.INFO)
				end)
			end,
		},
		{
			label = "Refresh",
			action = function()
				refresh(session)
			end,
		},
	}

	if #editable > 0 then
		table.insert(commands, { label = "───────────────", action = false })
		for _, entry in ipairs(editable) do
			table.insert(commands, {
				label = entry.name or (" " .. entry.field),
				action = function()
					start_edit(session, entry)
				end,
			})
		end
	end

	require("honcho").honcho_picker("Airtable record", commands)()
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

---@param session AirtableSession
local function region_at_cursor(session)
	local row, col = current_cursor(session)
	if not row then
		return nil
	end
	return regions.at(session.buf, session.regions, row, col), row, col
end

---@param session AirtableSession
local function set_keymaps(session)
	local buf = session.buf
	local function map(mode, lhs, rhs, desc, expr)
		vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, expr = expr, nowait = true })
	end

	map("n", "<CR>", function()
		open_context_menu(session)
	end, "Airtable record actions")

	map("n", "go", function()
		local url = url_under_cursor()
		if not url then
			notify("No URL", "no URL under cursor", vim.log.levels.INFO)
			return
		end
		vim.ui.open(url)
	end, "Open URL under cursor")

	-- On a select field's section, `e` opens its choices; elsewhere it's the motion.
	map("n", "e", function()
		local key = section_key_at_cursor(session)
		local field_entry = key and config.buffer_field_by_key(key)
		local entry = field_entry and config.editable_entry(field_entry.field)
		if entry and entry.type == "select" then
			vim.schedule(function()
				start_select(session, entry)
			end)
			return ""
		end
		return "e"
	end, "Edit select field under cursor / end of word", true)

	-- Single-line fields can't gain a line.
	local function guard_single_line(key)
		return function()
			local region = region_at_cursor(session)
			if region and region.single_line then
				return ""
			end
			return key
		end
	end
	map("n", "o", guard_single_line("o"), "Open line below", true)
	map("n", "O", guard_single_line("O"), "Open line above", true)
	map("i", "<CR>", guard_single_line("<CR>"), "New line", true)

	-- Don't join a field with the read-only text around it.
	map("i", "<BS>", function()
		local region, row, col = region_at_cursor(session)
		if region and regions.is_at_start(buf, region, row, col) then
			return ""
		end
		return "<BS>"
	end, "Backspace", true)
	map("i", "<Del>", function()
		local region, row, col = region_at_cursor(session)
		if region and regions.is_at_end(buf, region, row, col) then
			return ""
		end
		return "<Del>"
	end, "Delete", true)
end

---@param session AirtableSession
local function close_session(session)
	if session.closed then
		return
	end
	if autosave.is_dirty(session) then
		autosave.flush_sync(session)
	end
	autosave.close(session)
	sessions[session.buf] = nil
	if buffers_by_record[session.record_id] == session.buf then
		buffers_by_record[session.record_id] = nil
	end
	pcall(vim.api.nvim_del_augroup_by_name, "airtable_buffer_" .. session.buf)
end

---@param session AirtableSession
local function set_autocmds(session)
	local buf = session.buf
	local group = vim.api.nvim_create_augroup("airtable_buffer_" .. buf, { clear = true })
	local function on(events, fn)
		vim.api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn })
	end

	on({ "TextChanged", "TextChangedI", "TextChangedP" }, function()
		on_change(session)
	end)
	on({ "CursorMoved", "CursorMovedI", "BufEnter", "InsertEnter" }, function()
		update_gate(session)
	end)
	on("BufWriteCmd", function()
		autosave.flush_sync(session)
	end)
	-- Deferred a tick: when the buffer is being deleted, BufUnload runs right after and
	-- saves synchronously; the deferred flush then sees the closed session and skips.
	on({ "BufLeave", "BufHidden" }, function()
		vim.schedule(function()
			if not session.closed and autosave.is_dirty(session) then
				autosave.flush(session)
			end
		end)
	end)
	on({ "BufUnload", "BufWipeout" }, function()
		close_session(session)
	end)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("airtable_view", { clear = true }),
	callback = function()
		for _, session in pairs(sessions) do
			if not session.closed and autosave.is_dirty(session) then
				autosave.flush_sync(session)
			end
		end
	end,
})

M.FILETYPE = "airtable"

-- Own filetype, highlighted with the markdown treesitter parser: markdown highlighting
-- without the user's markdown linters, LSPs, formatters and renderers attaching. They'd
-- flag the layout (blank lines, heading style) and a formatter rewriting the buffer on
-- `:w` would fight the read-only structure.
---@param buf integer
local function set_filetype(buf)
	pcall(vim.treesitter.language.register, "markdown", M.FILETYPE)
	vim.bo[buf].filetype = M.FILETYPE
	-- Formatters configured for every filetype: opt out (conform / LazyVim conventions).
	vim.b[buf].disable_autoformat = true
	vim.b[buf].autoformat = false
	if not pcall(vim.treesitter.start, buf, "markdown") then
		vim.bo[buf].syntax = "markdown"
	end
end

---@param record AirtableRecord
---@param field_types table<string, string>?
---@return AirtableSession
local function create_session(record, field_types)
	local buf = vim.api.nvim_create_buf(false, true)
	-- acwrite: `:w` runs BufWriteCmd (save now), and 'modified' tracks unsaved edits.
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	set_filetype(buf)

	---@type AirtableSession
	local session = {
		buf = buf,
		record_id = record.id,
		record = record,
		field_types = field_types,
		regions = {},
		baseline = {},
		saving = false,
		pending = false,
		has_saved = false,
		closed = false,
	}
	session.on_saved = function()
		update_name(session)
	end
	sessions[buf] = session
	buffers_by_record[record.id] = buf

	update_name(session)
	render_into(session, record)
	set_keymaps(session)
	set_autocmds(session)
	return session
end

local warned_types = {}

-- `type = "text"` only works for fields whose value is text (or a number).
---@param field_types table<string, string>
local function warn_unsupported_types(field_types)
	for _, entry in ipairs(config.options.buffer.editable or {}) do
		local field_type = field_types[entry.field]
		if entry.type == "text" and field_type and not render.INLINE_TYPES[field_type] then
			if not warned_types[entry.field] then
				warned_types[entry.field] = true
				notify(
					"Config Error",
					string.format(
						'"buffer.editable" field "%s" is a %s field: type = "text" only supports text and number fields',
						entry.field,
						field_type
					),
					vim.log.levels.WARN
				)
			end
		end
	end
end

local function has_inline_fields()
	for _, entry in ipairs(config.options.buffer.editable or {}) do
		if entry.type == "text" then
			return true
		end
	end
	return false
end

-- Field types are needed to tell single-line fields apart and reject non-text ones.
-- The schema is cached, so this costs one request per session at most.
local function with_field_types(callback)
	if not has_inline_fields() then
		callback(nil)
		return
	end
	api.get_field_types(function(field_types, err)
		if err then
			notify(err.category, "couldn't load field types: " .. err.message, vim.log.levels.WARN)
			callback(nil)
			return
		end
		warn_unsupported_types(field_types)
		callback(field_types)
	end)
end

---@param record_id string
---@param opts { focus_field: string? }? focus_field: put the cursor in that field, in insert mode
function M.open(record_id, opts)
	opts = opts or {}
	notify("Loading", "fetching record...", vim.log.levels.INFO)
	with_field_types(function(field_types)
		api.get_recordById(record_id, function(record, err)
			if err then
				notify(err.category, err.message, vim.log.levels.ERROR)
				return
			end
			if not record then
				notify("No Record", string.format('no record found for id "%s"', record_id), vim.log.levels.INFO)
				return
			end

			last_record_id = record.id
			local buf = buffers_by_record[record.id]
			local session = buf and sessions[buf]
			if session and vim.api.nvim_buf_is_valid(buf) then
				session.field_types = field_types or session.field_types
				render_into(session, record, { preserve_dirty = true })
				autosave.reset_status(session)
				update_name(session)
			else
				session = create_session(record, field_types)
			end

			vim.api.nvim_set_current_buf(session.buf)
			update_gate(session)
			if opts.focus_field then
				M.focus_field(session, opts.focus_field)
			end
		end)
	end)
end

return M
