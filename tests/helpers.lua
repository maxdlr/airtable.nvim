local M = {}

M.FIELDS = {
	{ key = "title", field = "Title" },
	{ key = "status", field = "Status" },
	{ key = "description", field = "Description" },
	{ key = "pr_link", field = "PR link" },
	{ key = "estimate", field = "Estimate" },
	{ key = "notes", field = "Notes" },
}

M.FIELD_TYPES = {
	Title = "singleLineText",
	Status = "singleSelect",
	Description = "multilineText",
	["PR link"] = "url",
	Estimate = "number",
	Notes = "multilineText",
}

-- Silences toasts and records them instead.
function M.capture_notifications()
	local notified = {}
	local original = vim.notify
	vim.notify = function(message, level, opts)
		table.insert(notified, { message = message, level = level, title = opts and opts.title })
	end
	return notified, function()
		vim.notify = original
	end
end

---@param overrides table?
function M.setup(overrides)
	require("airtable.config").setup(vim.tbl_deep_extend("force", {
		base_id = "appTEST",
		table_name = "Tickets",
		buffer = {
			fields = vim.deepcopy(M.FIELDS),
			editable = {
				{ field = "Title", type = "text" },
				{ field = "Status", type = "select" },
				{ field = "Description", type = "text" },
				{ field = "PR link", type = "text" },
				{ field = "Estimate", type = "text" },
			},
			autosave = { enabled = true, debounce_ms = 20 },
		},
	}, overrides or {}))
end

function M.record(fields, id)
	return { id = id or "recTEST1", createdTime = "2026-01-01T00:00:00.000Z", fields = fields }
end

-- Replaces module functions for the duration of a test; call the result to restore.
---@param mod table
---@param replacements table<string, function>
function M.stub(mod, replacements)
	local originals = {}
	for name, fn in pairs(replacements) do
		originals[name] = mod[name]
		mod[name] = fn
	end
	return function()
		for name, fn in pairs(originals) do
			mod[name] = fn
		end
	end
end

---@param condition fun(): boolean
function M.wait_for(condition, timeout)
	return vim.wait(timeout or 1000, condition, 5)
end

return M
