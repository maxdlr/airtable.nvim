-- Saves a record buffer's edited regions back to Airtable.
--
-- A field is dirty when its region's text differs from its baseline (the value last
-- known to be on Airtable). Every change restarts one debounce timer per buffer; when
-- it fires, all dirty fields go out in a single PATCH. Saves never overlap: edits made
-- while one is in flight queue another save right after it.
--
-- The buffer is never re-rendered from a save's response, since the user may still be
-- typing; only the baselines move.

local api = require("airtable.api")
local config = require("airtable.config")
local regions = require("airtable.regions")
local render = require("airtable.render")
local notify = require("airtable.notify").notify

local M = {}

M.STATUS_NS = vim.api.nvim_create_namespace("airtable_autosave_status")

local STATUS_CHUNKS = {
	dirty = { "● unsaved", "DiagnosticWarn" },
	saving = { "… saving", "Comment" },
	saved = { "✓ saved", "DiagnosticOk" },
	error = { "✗ not saved", "DiagnosticError" },
}

---@class AirtableSession
---@field buf integer
---@field record_id string
---@field record AirtableRecord Last full record known (for re-rendering static parts)
---@field regions AirtableRegion[]
---@field baseline table<string, string> field -> text last known on Airtable
---@field timer uv.uv_timer_t?
---@field saving boolean
---@field pending boolean
---@field status 'dirty'|'saving'|'saved'|'error'|nil
---@field last_error string?
---@field has_saved boolean
---@field closed boolean
---@field on_saved fun(record: AirtableRecord)?

---@param session AirtableSession
local function set_status(session, status)
	session.status = status
	if session.closed or not vim.api.nvim_buf_is_valid(session.buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(session.buf, M.STATUS_NS, 0, -1)
	local chunk = status and STATUS_CHUNKS[status]
	if chunk then
		pcall(vim.api.nvim_buf_set_extmark, session.buf, M.STATUS_NS, 0, 0, {
			virt_text = { { "  " .. chunk[1], chunk[2] } },
			virt_text_pos = "eol",
			priority = 1,
		})
	end
end

-- Buffer text -> value sent to Airtable.
---@param region AirtableRegion
---@param text string
---@return any value
---@return string? err
function M.coerce(region, text)
	if render.NUMERIC_TYPES[region.field_type or ""] then
		local trimmed = vim.trim(text)
		if trimmed == "" then
			return vim.NIL
		end
		local number = tonumber(trimmed)
		if not number then
			return nil, string.format('%s: "%s" is not a number', region.field, trimmed)
		end
		return number
	end
	return text
end

---@param region AirtableRegion
local function current_text(session, region)
	local text = regions.text(session.buf, region)
	if region.single_line then
		text = text:gsub("\n", " ")
	end
	return text
end

---@param session AirtableSession
---@return boolean
function M.is_dirty(session)
	for _, region in ipairs(session.regions) do
		if current_text(session, region) ~= session.baseline[region.field] then
			return true
		end
	end
	return false
end

---@param session AirtableSession
---@return table<string, any> fields Values to PATCH
---@return table<string, string> texts Buffer text of each field in `fields`
---@return string[] errors Fields that are dirty but can't be sent (e.g. bad number)
function M.pending_changes(session)
	local fields, texts, errors = {}, {}, {}
	for _, region in ipairs(session.regions) do
		local text = current_text(session, region)
		if text ~= session.baseline[region.field] then
			local value, err = M.coerce(region, text)
			if err then
				table.insert(errors, err)
			else
				fields[region.field] = value
				texts[region.field] = text
			end
		end
	end
	return fields, texts, errors
end

---@param session AirtableSession
function M.refresh_status(session)
	local dirty = M.is_dirty(session)
	if session.closed or not vim.api.nvim_buf_is_valid(session.buf) then
		return
	end
	vim.bo[session.buf].modified = dirty
	if session.saving then
		set_status(session, "saving")
	elseif dirty and session.last_error then
		set_status(session, "error")
	elseif dirty then
		set_status(session, "dirty")
	elseif session.last_error then
		set_status(session, "error")
	else
		set_status(session, session.has_saved and "saved" or nil)
	end
end

-- Toasts once per run of failures: further failures stay silent (the status
-- indicator keeps showing them) until a save succeeds again.
local function report_error(session, category, message)
	if not session.last_error then
		notify(category, message, vim.log.levels.ERROR)
	end
	session.last_error = message
end

local function stop_timer(session)
	if session.timer then
		session.timer:stop()
	end
end

local function apply_saved(session, texts, errors, record)
	for field, text in pairs(texts) do
		session.baseline[field] = text
	end
	session.has_saved = true
	if record then
		session.record = record
	end
	if #errors == 0 then
		session.last_error = nil
	end
	if session.on_saved and record then
		session.on_saved(record)
	end
end

---@param session AirtableSession
function M.flush(session)
	stop_timer(session)
	if session.closed then
		return
	end
	if session.saving then
		session.pending = true
		return
	end

	local fields, texts, errors = M.pending_changes(session)
	if #errors > 0 then
		report_error(session, "Invalid Value", errors[1])
	end
	if next(fields) == nil then
		M.refresh_status(session)
		return
	end

	session.saving = true
	M.refresh_status(session)
	api.update_record(session.record_id, fields, function(record, err)
		session.saving = false
		if session.closed then
			return
		end
		if err then
			report_error(session, err.category, err.message)
		else
			apply_saved(session, texts, errors, record)
		end
		if session.pending then
			session.pending = false
			M.flush(session)
			return
		end
		M.refresh_status(session)
	end)
end

-- Blocking save, for when the buffer or Neovim is going away, or the user asked
-- explicitly (`:w`). Returns the updated record if anything was saved.
---@param session AirtableSession
---@return AirtableRecord?
---@return AirtableError?
function M.flush_sync(session)
	stop_timer(session)
	local fields, texts, errors = M.pending_changes(session)
	if #errors > 0 then
		report_error(session, "Invalid Value", errors[1])
	end
	if next(fields) == nil then
		M.refresh_status(session)
		return nil, nil
	end

	local record, err = api.update_record(session.record_id, fields)
	if err then
		report_error(session, err.category, err.message)
	else
		apply_saved(session, texts, errors, record)
	end
	M.refresh_status(session)
	return record, err
end

-- Call after every user edit.
---@param session AirtableSession
function M.changed(session)
	M.refresh_status(session)
	local opts = config.options.buffer.autosave
	if not opts.enabled then
		return
	end
	if not session.timer then
		session.timer = assert(vim.uv.new_timer())
	end
	session.timer:stop()
	session.timer:start(
		opts.debounce_ms,
		0,
		vim.schedule_wrap(function()
			M.flush(session)
		end)
	)
end

-- Clears the status indicator (e.g. after a full re-render from Airtable).
function M.reset_status(session)
	session.has_saved = false
	M.refresh_status(session)
end

---@param session AirtableSession
function M.close(session)
	session.closed = true
	if session.timer then
		session.timer:stop()
		if not session.timer:is_closing() then
			session.timer:close()
		end
		session.timer = nil
	end
end

return M
