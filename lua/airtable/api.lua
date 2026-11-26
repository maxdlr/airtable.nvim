local config = require("airtable.config")

local M = {}

local API_URL = "https://api.airtable.com/v0"

---@class AirtableRecord
---@field id string
---@field createdTime string
---@field fields table<string, any>

---@class AirtableError
---@field category string
---@field message string

-- Flattens linked records/multi-select (array) and collaborators ({id,email,name} or
-- an array of those) to plain comma-separated text.
function M.format_field(value)
	if value == nil then
		return ""
	end
	if type(value) == "string" or type(value) == "number" then
		return tostring(value)
	end
	if type(value) == "table" then
		if value.name then
			return tostring(value.name)
		end
		local parts = {}
		for _, item in ipairs(value) do
			if type(item) == "table" then
				table.insert(parts, tostring(item.name or item.id or vim.inspect(item)))
			else
				table.insert(parts, tostring(item))
			end
		end
		return table.concat(parts, ", ")
	end
	return tostring(value)
end

-- Placeholders: {DD} {MM} {YYYY} {HH} {mm}. Overridable via config.date_formats.
local DEFAULT_DATE_TEMPLATES = {
	datetime = "{DD}/{MM}/{YYYY} - {HH}:{mm}",
	date = "{DD}/{MM}/{YYYY}",
	time = "{HH}:{mm}",
	short_date = "{DD}/{MM}",
	short_date_with_year = "{DD}/{MM}/{YYYY}",
}

function M.looks_like_date(text)
	return text:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d") ~= nil
end

-- Non-matching text is returned unchanged rather than erroring.
---@param mode 'datetime'|'date'|'time'|'short_date'
function M.format_date(text, mode)
	local year, month, day, hour, minute = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
	if not year then
		return text
	end

	local resolved_mode = mode
	if mode == "short_date" and year ~= os.date("%Y") then
		resolved_mode = "short_date_with_year"
	end

	local configured = config.options.date_formats and config.options.date_formats[resolved_mode]
	local template = configured or DEFAULT_DATE_TEMPLATES[resolved_mode]

	return (template:gsub("{(%a+)}", {
		DD = day,
		MM = month,
		YYYY = year,
		HH = hour,
		mm = minute,
	}))
end

-- RFC 3986 percent-encoding for path segments (table name can contain
-- spaces/emoji/non-ASCII; plenary.curl's `query` option only encodes query values).
local function encode_path_segment(segment)
	return (segment:gsub("([^%w%-%.%_%~])", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

local function table_path()
	local opts = config.options
	return string.format("%s/%s/%s", API_URL, opts.base_id, encode_path_segment(opts.table_name))
end

local function record_path(record_id)
	return table_path() .. "/" .. encode_path_segment(record_id)
end

local function list_query(formula, sort, offset)
	local query = { pageSize = tostring(config.options.page_size) }
	if formula then
		query.filterByFormula = formula
	end
	if sort then
		query["sort[0][field]"] = sort.field
		query["sort[0][direction]"] = sort.order or "asc"
	end
	if offset then
		query.offset = offset
	end
	return query
end

-- vim.json.decode turns JSON null into vim.NIL (truthy in `if`), not Lua nil.
local function next_offset(decoded)
	local offset = decoded.offset
	if offset == nil or offset == vim.NIL then
		return nil
	end
	return offset
end

local MISSING_TOKEN = { category = "Missing Token", message = "no Airtable personal access token configured" }

---@return table? decoded
---@return AirtableError? err
local function handle_response(response)
	if not response or response.status ~= 200 then
		return nil,
			{
				category = string.format("API Error (%s)", response and response.status or "?"),
				message = (response and response.body) or "no response body",
			}
	end
	local ok, decoded = pcall(vim.json.decode, response.body)
	if not ok or type(decoded) ~= "table" then
		return nil, { category = "Response Error", message = "failed to decode Airtable response" }
	end
	return decoded, nil
end

-- Single entry point for every HTTP call. With a callback it's async (callback runs on
-- the main loop); without one it blocks and returns (decoded, err) — only used where
-- we must not lose data, e.g. saving pending edits on :w or when Neovim exits.
---@param method 'get'|'patch'
---@param url string
---@param opts { query: table?, body: table? }
---@param callback fun(decoded: table?, err: AirtableError?)?
---@return table? decoded
---@return AirtableError? err
local function request(method, url, opts, callback)
	local function finish(decoded, err)
		if callback then
			callback(decoded, err)
			return
		end
		return decoded, err
	end

	local token = config.token()
	if not token then
		return finish(nil, MISSING_TOKEN)
	end

	local headers = { Authorization = "Bearer " .. token }
	local body
	if opts.body then
		local ok, encoded = pcall(vim.json.encode, opts.body)
		if not ok then
			return finish(nil, { category = "Request Error", message = "failed to encode request body" })
		end
		body = encoded
		headers["Content-Type"] = "application/json"
	end

	local args = {
		query = opts.query,
		headers = headers,
		body = body,
		-- "-g": disable curl's URL globbing, or "[" / "]" in sort[0][field] breaks the request.
		raw = { "-g" },
	}

	local curl = require("plenary.curl")
	if callback then
		args.callback = vim.schedule_wrap(function(response)
			callback(handle_response(response))
		end)
		args.on_error = vim.schedule_wrap(function(e)
			callback(nil, { category = "Network Error", message = e.message or "request failed" })
		end)
		curl[method](url, args)
		return
	end

	args.on_error = function(e)
		error(e.message or "request failed", 0)
	end
	local ok, response = pcall(curl[method], url, args)
	if not ok then
		return nil, { category = "Network Error", message = tostring(response) }
	end
	return handle_response(response)
end

-- Follows Airtable's `offset` pagination, collecting `decoded[list_key]` from each page.
local function fetch_all(url, list_key, make_query, callback)
	local items = {}
	local function fetch_page(offset)
		request("get", url, { query = make_query(offset) }, function(decoded, err)
			if err then
				callback(nil, err)
				return
			end
			vim.list_extend(items, decoded[list_key] or {})
			local next = next_offset(decoded)
			if next then
				fetch_page(next)
			else
				callback(items, nil)
			end
		end)
	end
	fetch_page(nil)
end

function M.list_records(formula, sort, callback)
	fetch_all(table_path(), "records", function(offset)
		return list_query(formula, sort, offset)
	end, callback)
end

-- Airtable's comments endpoint 422s on a `sort` param, unlike the records endpoint,
-- and returns { comments: [...] } instead of { records: [...] }.
function M.list_record_comments(record_id, callback)
	fetch_all(record_path(record_id) .. "/comments", "comments", function(offset)
		return list_query(nil, nil, offset)
	end, callback)
end

-- Returns the record object directly, not { records: [...] }.
function M.get_recordById(record_id, callback)
	request("get", record_path(record_id), {}, callback)
end

-- base_id -> table schema, cached for the session.
local table_schema_cache = {}

local function get_table_schema(callback)
	local opts = config.options
	local cached = table_schema_cache[opts.base_id]
	if cached then
		callback(cached, nil)
		return
	end

	request("get", string.format("%s/meta/bases/%s/tables", API_URL, opts.base_id), {}, function(decoded, err)
		if err then
			callback(nil, err)
			return
		end
		for _, table_info in ipairs(decoded.tables or {}) do
			if table_info.name == opts.table_name or table_info.id == opts.table_name then
				table_schema_cache[opts.base_id] = table_info
				callback(table_info, nil)
				return
			end
		end
		callback(nil, {
			category = "Config Error",
			message = string.format('table "%s" not found in base "%s"', opts.table_name, opts.base_id),
		})
	end)
end

-- Record URLs use the table id (tblXXX), not its display name.
function M.get_table_id(callback)
	get_table_schema(function(table_info, err)
		if err then
			callback(nil, err)
			return
		end
		callback(table_info.id, nil)
	end)
end

-- Field name -> Airtable field type (e.g. "singleLineText", "multilineText").
---@param callback fun(types: table<string, string>?, err: AirtableError?)
function M.get_field_types(callback)
	get_table_schema(function(table_info, err)
		if err then
			callback(nil, err)
			return
		end
		local types = {}
		for _, field in ipairs(table_info.fields or {}) do
			types[field.name] = field.type
		end
		callback(types, nil)
	end)
end

function M.get_field_choices(field_name, callback)
	get_table_schema(function(table_info, err)
		if err then
			callback(nil, err)
			return
		end

		for _, field in ipairs(table_info.fields or {}) do
			if field.name == field_name then
				local choices = field.options and field.options.choices
				if not choices then
					callback(nil, {
						category = "Config Error",
						message = string.format('field "%s" is not a select field (no choices)', field_name),
					})
					return
				end
				callback(
					vim.tbl_map(function(choice)
						return choice.name
					end, choices),
					nil
				)
				return
			end
		end

		callback(nil, { category = "Config Error", message = string.format('field "%s" not found', field_name) })
	end)
end

-- PATCH leaves every field not in `fields` untouched. Without a callback, blocks and
-- returns (record, err).
---@param record_id string
---@param fields table<string, any>
---@param callback fun(record: AirtableRecord?, err: AirtableError?)?
---@return AirtableRecord?
---@return AirtableError?
function M.update_record(record_id, fields, callback)
	return request("patch", record_path(record_id), { body = { fields = fields } }, callback)
end

function M.record_url(record_id, callback)
	local opts = config.options
	M.get_table_id(function(table_id, err)
		if err then
			callback(nil, err)
			return
		end
		callback(string.format("https://airtable.com/%s/%s/%s", opts.base_id, table_id, record_id), nil)
	end)
end

-- Test hook: drops the cached schema.
function M._reset_cache()
	table_schema_cache = {}
end

return M
