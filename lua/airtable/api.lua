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
}

function M.looks_like_date(text)
	return text:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d") ~= nil
end

-- Non-matching text is returned unchanged rather than erroring.
---@param mode 'datetime'|'date'|'time'
function M.format_date(text, mode)
	local year, month, day, hour, minute = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
	if not year then
		return text
	end

	local configured = config.options.date_formats and config.options.date_formats[mode]
	local template = configured or DEFAULT_DATE_TEMPLATES[mode]

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

local function build_table_path()
	local opts = config.options
	return string.format("%s/%s/%s", API_URL, opts.base_id, encode_path_segment(opts.table_name))
end

local function build_query(formula, sort, offset)
	local opts = config.options
	local query = { pageSize = tostring(opts.page_size) }
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

function M.list_records(formula, sort, callback)
	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	local records = {}
	local path = build_table_path()

	local function fetch_page(offset)
		curl.get(path, {
			query = build_query(formula, sort, offset),
			headers = { Authorization = "Bearer " .. token },
			-- "-g": disable curl's URL globbing, or "[" / "]" in sort[0][field] breaks the request.
			raw = { "-g" },
			callback = vim.schedule_wrap(function(response)
				if response.status ~= 200 then
					callback(nil, {
						category = string.format("API Error (%d)", response.status),
						message = response.body or "no response body",
					})
					return
				end

				local ok, decoded = pcall(vim.json.decode, response.body)
				if not ok then
					callback(nil, { category = "Response Error", message = "failed to decode Airtable response" })
					return
				end

				vim.list_extend(records, decoded.records or {})

				local offset = next_offset(decoded)
				if offset then
					fetch_page(offset)
				else
					callback(records, nil)
				end
			end),
		})
	end

	fetch_page(nil)
end

local function build_record_comments_path(record_id)
	local opts = config.options
	return string.format(
		"%s/%s/%s/%s/%s",
		API_URL,
		opts.base_id,
		encode_path_segment(opts.table_name),
		encode_path_segment(record_id),
		"comments"
	)
end

-- Airtable's comments endpoint 422s on a `sort` param, unlike the records endpoint.
function M.list_record_comments(record_id, callback)
	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	local comments = {}
	local path = build_record_comments_path(record_id)

	local function fetch_page(offset)
		curl.get(path, {
			query = build_query(nil, nil, offset),
			headers = { Authorization = "Bearer " .. token },
			raw = { "-g" },
			callback = vim.schedule_wrap(function(response)
				if response.status ~= 200 then
					callback(nil, {
						category = string.format("API Error (%d)", response.status),
						message = response.body or "no response body",
					})
					return
				end

				local ok, decoded = pcall(vim.json.decode, response.body)
				if not ok then
					callback(nil, { category = "Response Error", message = "failed to decode Airtable response" })
					return
				end

				-- Comments endpoint returns { comments: [...] }, not { records: [...] }.
				vim.list_extend(comments, decoded.comments or {})

				local offset = next_offset(decoded)
				if offset then
					fetch_page(offset)
				else
					callback(comments, nil)
				end
			end),
		})
	end

	fetch_page(nil)
end

local function build_record_path(record_id)
	local opts = config.options
	return string.format(
		"%s/%s/%s/%s",
		API_URL,
		opts.base_id,
		encode_path_segment(opts.table_name),
		encode_path_segment(record_id)
	)
end

function M.get_recordById(record_id, callback)
	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	local path = build_record_path(record_id)

	curl.get(path, {
		headers = { Authorization = "Bearer " .. token },
		raw = { "-g" },
		callback = vim.schedule_wrap(function(response)
			if response.status ~= 200 then
				callback(nil, {
					category = string.format("API Error (%d)", response.status),
					message = response.body or "no response body",
				})
				return
			end

			-- Returns the record object directly, not { records: [...] }.
			local ok, decoded = pcall(vim.json.decode, response.body)
			if not ok then
				callback(nil, { category = "Response Error", message = "failed to decode Airtable response" })
				return
			end

			callback(decoded, nil)
		end),
	})
end

-- base_id -> table id / full schema, cached for the session.
local table_id_cache = {}
local table_schema_cache = {}

local function get_table_schema(callback)
	local opts = config.options
	local cached = table_schema_cache[opts.base_id]
	if cached then
		callback(cached, nil)
		return
	end

	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	curl.get(string.format("%s/meta/bases/%s/tables", API_URL, opts.base_id), {
		headers = { Authorization = "Bearer " .. token },
		raw = { "-g" },
		callback = vim.schedule_wrap(function(response)
			if response.status ~= 200 then
				callback(nil, {
					category = string.format("API Error (%d)", response.status),
					message = response.body or "no response body",
				})
				return
			end

			local ok, decoded = pcall(vim.json.decode, response.body)
			if not ok then
				callback(nil, { category = "Response Error", message = "failed to decode Airtable response" })
				return
			end

			for _, table_info in ipairs(decoded.tables or {}) do
				if table_info.name == opts.table_name or table_info.id == opts.table_name then
					table_schema_cache[opts.base_id] = table_info
					table_id_cache[opts.base_id] = table_info.id
					callback(table_info, nil)
					return
				end
			end

			callback(nil, {
				category = "Config Error",
				message = string.format('table "%s" not found in base "%s"', opts.table_name, opts.base_id),
			})
		end),
	})
end

-- Record URLs use the table id (tblXXX), not its display name.
function M.get_table_id(callback)
	local opts = config.options
	local cached = table_id_cache[opts.base_id]
	if cached then
		callback(cached, nil)
		return
	end

	get_table_schema(function(table_info, err)
		if err then
			callback(nil, err)
			return
		end
		callback(table_info.id, nil)
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
					vim.tbl_map(function(choice) return choice.name end, choices),
					nil
				)
				return
			end
		end

		callback(nil, { category = "Config Error", message = string.format('field "%s" not found', field_name) })
	end)
end

-- PATCH leaves every other field on the record untouched.
function M.update_record(record_id, field_name, value, callback)
	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	local path = build_record_path(record_id)
	local ok, body = pcall(vim.json.encode, { fields = { [field_name] = value } })
	if not ok then
		callback(nil, { category = "Request Error", message = "failed to encode request body" })
		return
	end

	curl.patch(path, {
		headers = {
			Authorization = "Bearer " .. token,
			["Content-Type"] = "application/json",
		},
		body = body,
		raw = { "-g" },
		callback = vim.schedule_wrap(function(response)
			if response.status ~= 200 then
				callback(nil, {
					category = string.format("API Error (%d)", response.status),
					message = response.body or "no response body",
				})
				return
			end

			local decode_ok, decoded = pcall(vim.json.decode, response.body)
			if not decode_ok then
				callback(nil, { category = "Response Error", message = "failed to decode Airtable response" })
				return
			end

			callback(decoded, nil)
		end),
	})
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

return M
