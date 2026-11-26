local api = require("airtable.api")
local notify = require("airtable.notify").notify

-- Picker-based editing, for select fields. Text fields are edited directly in the
-- record buffer (see airtable.view).

local M = {}

---@param on_closed? fun() Called once the picker closes, whether confirmed or cancelled.
function M.edit_select(record_id, field, on_updated, on_closed)
	api.get_field_choices(field, function(choices, err)
		if err then
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		if #choices == 0 then
			notify("No Choices", string.format('field "%s" has no configured choices', field), vim.log.levels.INFO)
			return
		end

		local title = " " .. field
		local longest = #title
		for _, choice in ipairs(choices) do
			longest = math.max(longest, #choice)
		end
		-- Padding for borders; capped so short/long choice lists both look reasonable.
		local width = math.max(30, math.min(80, longest + 10))
		local height = math.max(5, math.min(15, #choices + 3))

		local items = {}
		for _, choice in ipairs(choices) do
			table.insert(items, { text = choice })
		end

		Snacks.picker.pick({
			title = title,
			items = items,
			format = function(item)
				return { { item.text, "Normal" } }
			end,
			layout = {
				preset = "select",
				layout = { width = width, min_width = width, max_width = width, max_height = height },
			},
			on_show = function(picker)
				-- Retries startinsert until the input window is actually focused, since a
				-- single call can race with a parent picker's close() and get dropped.
				local attempts = 0
				local function try_insert()
					attempts = attempts + 1
					if not picker.input or not picker.input.win:valid() then
						return
					end
					if vim.api.nvim_get_current_win() == picker.input.win.win then
						vim.cmd("startinsert!")
					elseif attempts < 10 then
						vim.defer_fn(try_insert, 20)
					end
				end
				vim.schedule(try_insert)
			end,
			on_close = on_closed,
			confirm = function(picker, item)
				picker:close()
				if not item then
					return
				end

				api.update_record(record_id, { [field] = item.text }, function(record, update_err)
					if update_err then
						notify(update_err.category, update_err.message, vim.log.levels.ERROR)
						return
					end
					notify("Updated", string.format('%s set to "%s"', field, item.text), vim.log.levels.INFO)
					on_updated(record)
				end)
			end,
		})
	end)
end

return M
