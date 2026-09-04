local config = require("airtable.config")

local M = {}

local API_URL = "https://api.airtable.com/v0"

---@class AirtableRecord
---@field id string
---@field createdTime string
---@field fields table<string, any>

---@class AirtableError
---@field category string Short category shown in the toast title, e.g. "API Error"
---@field message string

---Formats a raw Airtable field value for display as plain text. Airtable represents
---some field types beyond plain strings/numbers:
---  - linked records / multi-select: array of strings or record ids
---  - collaborators: array of `{ id, email, name }` objects (or a single one)
---Both are flattened to a comma-separated string of their readable parts.
---@param value any
---@return string
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
		end -- single collaborator object
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

---Reformats an Airtable ISO-8601 timestamp (e.g. "2026-09-03T21:09:34.000Z") for display.
---Returns `text` unchanged if it doesn't match the expected timestamp shape, so a
---misconfigured `date_format` on a non-date field never breaks the render.
---@param text string Already-formatted field text (see `format_field`)
---@param mode 'datetime'|'date'|'time'
---@return string
function M.format_date(text, mode)
	local year, month, day, hour, minute = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
	if not year then
		return text
	end

	local date_part = string.format("%s/%s/%s", day, month, year)
	local time_part = string.format("%s:%s", hour, minute)

	if mode == "date" then
		return date_part
	elseif mode == "time" then
		return time_part
	end
	return string.format("%s - %s", date_part, time_part)
end

---Percent-encodes a URL path segment (RFC 3986: keep alphanumerics and `-._~`, escape
---everything else as uppercase %XX). Used for the table name, since it can contain
---spaces/emoji/non-ASCII characters and is a path segment rather than a query value
---(`plenary.curl`'s `query` table option only encodes query values, not the path).
---@param segment string
---@return string
local function encode_path_segment(segment)
	return (segment:gsub("([^%w%-%.%_%~])", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

---Builds the request path (base + table, URL-escaped) for listing records. Query
---parameters (filter, sort, pagination) are passed separately as a table so
---`plenary.curl` can percent-encode them correctly — hand-building a query string with
---`vim.uri_encode` mishandles reserved characters like `{`, `}`, `[`, `]` used in Airtable
---formulas and `sort[0][field]`-style parameter names.
---@return string
local function build_table_path()
	local opts = config.options
	return string.format("%s/%s/%s", API_URL, opts.base_id, encode_path_segment(opts.table_name))
end

---Builds the query parameter table for one page of a list-records request.
---@param formula string?
---@param sort AirtableSort?
---@param offset string?
---@return table<string, string>
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

---Extracts the next-page offset from a decoded Airtable response, normalizing JSON
---`null` to Lua `nil`. `vim.json.decode` represents JSON `null` as the `vim.NIL`
---userdata sentinel, which is truthy in a plain `if` check — using it directly as an
---offset would send a malformed request instead of correctly stopping pagination.
---@param decoded table
---@return string?
local function next_offset(decoded)
	local offset = decoded.offset
	if offset == nil or offset == vim.NIL then
		return nil
	end
	return offset
end

---Fetches every page of records matching `formula` (optional) from Airtable, ordered by
---`sort` (optional).
---@param formula string?
---@param sort AirtableSort?
---@param callback fun(records: AirtableRecord[]?, err: AirtableError?)
function M.list_records(formula, sort, callback)
	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	local records = {}
	local path = build_table_path()

	---@param offset string?
	local function fetch_page(offset)
		curl.get(path, {
			query = build_query(formula, sort, offset),
			headers = { Authorization = "Bearer " .. token },
			-- Disable curl's URL globbing ("-g"): without it, curl interprets literal
			-- "[" / "]" in `sort[0][field]`-style query keys as its own range/glob syntax
			-- and fails with "bad range in URL" instead of sending the request.
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

---Builds the request path (base + table + record, URL-escaped) for a record's comments.
---@param record_id string
---@return string
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

---Fetches every page of comments on a specific record. Airtable's comments endpoint does
---not support a `sort` parameter (it 422s if one is sent), unlike the records endpoint.
---@param record_id string
---@param callback fun(comments: table[]?, err: AirtableError?)
function M.list_record_comments(record_id, callback)
	local token = config.token()
	if not token then
		callback(nil, { category = "Missing Token", message = "no Airtable personal access token configured" })
		return
	end

	local curl = require("plenary.curl")
	local comments = {}
	local path = build_record_comments_path(record_id)

	---@param offset string?
	local function fetch_page(offset)
		curl.get(path, {
			query = build_query(nil, nil, offset),
			headers = { Authorization = "Bearer " .. token },
			-- Disable curl's URL globbing ("-g"): without it, curl interprets literal
			-- "[" / "]" in query keys as its own range/glob syntax and fails with
			-- "bad range in URL" instead of sending the request.
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

				-- Airtable's comments endpoint returns `{ comments: [...] }`, unlike the
				-- records endpoint's `{ records: [...] }`.
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

---Builds the request path (base + table, URL-escaped) for a specific record. Query
---parameters (filter, sort, pagination) are passed separately as a table so
---`plenary.curl` can percent-encode them correctly — hand-building a query string with
---`vim.uri_encode` mishandles reserved characters like `{`, `}`, `[`, `]` used in Airtable
---formulas and `sort[0][field]`-style parameter names.
---@param record_id string
---@return string
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

---Fetches a single record by id from Airtable.
---@param record_id string
---@param callback fun(record: AirtableRecord?, err: AirtableError?)
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
		-- Disable curl's URL globbing ("-g"), same reasoning as in `list_records`.
		raw = { "-g" },
		callback = vim.schedule_wrap(function(response)
			if response.status ~= 200 then
				callback(nil, {
					category = string.format("API Error (%d)", response.status),
					message = response.body or "no response body",
				})
				return
			end

			-- Airtable's "get record" endpoint returns the record object directly
			-- (`{ id, createdTime, fields }`), unlike `list_records`'s `{ records: [...] }`.
			local ok, decoded = pcall(vim.json.decode, response.body)
			if not ok then
				callback(nil, { category = "Response Error", message = "failed to decode Airtable response" })
				return
			end

			callback(decoded, nil)
		end),
	})
end

-- Cache of base_id -> resolved table id, since it never changes for a given
-- table/base pair within a session and resolving it requires an extra API call.
local table_id_cache = {}

-- Cache of base_id -> full table schema (fields, including select choices), fetched once
-- per session and reused by both `get_table_id` and `get_field_choices`.
local table_schema_cache = {}

---Fetches the configured table's full schema (id, fields, field types/choices) via
---Airtable's metadata API, caching the result for the session.
---@param callback fun(table_info: table?, err: AirtableError?)
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

---Resolves the configured table's id (e.g. "tblXXXXXXXXXXXXXX"), needed to build
---Airtable web URLs (record URLs use the table id, not its display name). Looks it up
---via the metadata API on first use and caches the result for the session.
---@param callback fun(table_id: string?, err: AirtableError?)
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

---Fetches the list of valid choices for a `singleSelect`/`multipleSelects` field, via the
---table's metadata (Airtable does not expose field choices any other way). Returns an
---error if the field isn't found or isn't a select-type field.
---@param field_name string
---@param callback fun(choices: string[]?, err: AirtableError?)
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

---Updates a single field on a record via Airtable's PATCH endpoint. Only the given field
---is modified — Airtable's PATCH (as opposed to PUT) leaves every other field untouched.
---@param record_id string
---@param field_name string
---@param value any The new value for `field_name` (a plain string for text/select fields)
---@param callback fun(record: AirtableRecord?, err: AirtableError?)
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

---Builds the Airtable web URL for a record, resolving the table id first if needed.
---@param record_id string
---@param callback fun(url: string?, err: AirtableError?)
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
