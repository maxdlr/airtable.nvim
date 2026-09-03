local config = require("airtable.config")
local notify = require("airtable.notify").notify
local api = require("airtable.api")
local format_field = api.format_field

local M = {}

---Builds the markdown lines for a record from `buffer.fields`. The `title` key (if
---configured) becomes the H1 heading; every other key becomes its own section, titled
---with the key name capitalized (e.g. `tododev` -> "## Tododev").
---@param record AirtableRecord
---@return string[]
local function render_lines(record)
	local fields = config.options.buffer.fields
	local title = fields.title and format_field(record.fields[fields.title]) or ""
	if title == "" then
		title = "(untitled)"
	end

	local lines = { "# " .. title, "" }

	-- pairs() iteration order isn't guaranteed for string keys; sort alphabetically so
	-- section order is stable across runs. (If explicit ordering matters, this can be
	-- revisited to use an ordered list instead of a plain table for `fields`.)
	local other_keys = {}
	for key in pairs(fields) do
		if key ~= "title" then
			table.insert(other_keys, key)
		end
	end
	table.sort(other_keys)

	for _, key in ipairs(other_keys) do
		local field_name = fields[key]
		local text = format_field(record.fields[field_name])
		if text == "" then
			text = "_Empty._"
		end
		local heading = key:sub(1, 1):upper() .. key:sub(2)
		vim.list_extend(lines, { "## " .. heading, "" })
		vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
		table.insert(lines, "")
	end

	return lines
end

---Opens `vim.ui.select` with the record's available actions: open in browser, browse
---comments, or copy the record URL.
---@param record_id string
local function open_context_menu(record_id)
	local items = {
		'Open in browser',
		'Browse comments',
		'Copy record URL',
	}

	vim.ui.select(items, { prompt = 'Airtable record' }, function(choice)
		if not choice then
			return
		end

		if choice == 'Open in browser' then
			api.record_url(record_id, function(url, err)
				if err then
					notify(err.category, err.message, vim.log.levels.ERROR)
					return
				end
				vim.ui.open(url)
			end)
		elseif choice == 'Browse comments' then
			require("airtable.comments").pick(record_id)
		elseif choice == 'Copy record URL' then
			api.record_url(record_id, function(url, err)
				if err then
					notify(err.category, err.message, vim.log.levels.ERROR)
					return
				end
				vim.fn.setreg("+", url)
				notify("Copied", "record URL copied to clipboard", vim.log.levels.INFO)
			end)
		end
	end)
end

---Opens a non-writable scratch buffer showing the record formatted as markdown.
---@param record_id string
function M.open(record_id)
	api.get_recordById(record_id, function(record, err)
		if err then
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		if not record then
			notify("No Record", string.format('no record found for id "%s"', record_id), vim.log.levels.INFO)
			return
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(record))

		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.api.nvim_buf_set_name(buf, "airtable://" .. record.id)

		vim.keymap.set("n", "<CR>", function()
			open_context_menu(record.id)
		end, { buffer = buf, desc = "Airtable record actions" })

		vim.api.nvim_set_current_buf(buf)
	end)
end

return M
