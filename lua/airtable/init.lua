local config = require("airtable.config")

local M = {}

---@param opts AirtableConfig?
function M.setup(opts)
	config.setup(opts)
end

---@return string[]
function M.picker_names()
	return config.picker_names()
end

---@param picker_name string?
function M.open(picker_name)
	local picker = config.get_picker(picker_name)
	if not picker then
		-- config.get_picker already notified the specific reason (unknown name vs.
		-- malformed filter) via config.lua's own error path.
		return
	end

	require("airtable.picker").pick(picker, function(callback)
		require("airtable.api").list_records(picker.formula, picker.sort, function(records, err)
			if err then
				callback(nil, err)
				return
			end
			callback(config.filter_records(records, picker), nil)
		end)
	end)
end

function M.resume()
	local last_record_id = require("airtable.view").last_record_id()
	if last_record_id then
		require("airtable.view").open(last_record_id)
		return
	end
	M.open()
end

return M
