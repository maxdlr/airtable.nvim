local config = require 'airtable.config'

local M = {}

local API_URL = 'https://api.airtable.com/v0'

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
  if value == nil then return '' end
  if type(value) == 'string' or type(value) == 'number' then return tostring(value) end
  if type(value) == 'table' then
    if value.name then return tostring(value.name) end -- single collaborator object
    local parts = {}
    for _, item in ipairs(value) do
      if type(item) == 'table' then
        table.insert(parts, tostring(item.name or item.id or vim.inspect(item)))
      else
        table.insert(parts, tostring(item))
      end
    end
    return table.concat(parts, ', ')
  end
  return tostring(value)
end

---Percent-encodes a URL path segment (RFC 3986: keep alphanumerics and `-._~`, escape
---everything else as uppercase %XX). Used for the table name, since it can contain
---spaces/emoji/non-ASCII characters and is a path segment rather than a query value
---(`plenary.curl`'s `query` table option only encodes query values, not the path).
---@param segment string
---@return string
local function encode_path_segment(segment)
  return (segment:gsub('([^%w%-%.%_%~])', function(c) return string.format('%%%02X', c:byte()) end))
end

---Builds the request path (base + table, URL-escaped) for listing records. Query
---parameters (filter, sort, pagination) are passed separately as a table so
---`plenary.curl` can percent-encode them correctly — hand-building a query string with
---`vim.uri_encode` mishandles reserved characters like `{`, `}`, `[`, `]` used in Airtable
---formulas and `sort[0][field]`-style parameter names.
---@return string
local function build_path()
  local opts = config.options
  return string.format('%s/%s/%s', API_URL, opts.base_id, encode_path_segment(opts.table_name))
end

---Builds the query parameter table for one page of a list-records request.
---@param formula string?
---@param sort AirtableSort?
---@param offset string?
---@return table<string, string>
local function build_query(formula, sort, offset)
  local opts = config.options
  local query = { pageSize = tostring(opts.page_size) }
  if formula then query.filterByFormula = formula end
  if sort then
    query['sort[0][field]'] = sort.field
    query['sort[0][direction]'] = sort.order or 'asc'
  end
  if offset then query.offset = offset end
  return query
end

---Fetches every page of records matching `formula` (optional) from Airtable, ordered by
---`sort` (optional).
---@param formula string?
---@param sort AirtableSort?
---@param callback fun(records: AirtableRecord[]?, err: AirtableError?)
function M.list_records(formula, sort, callback)
  local token = config.token()
  if not token then
    callback(nil, { category = 'Missing Token', message = 'no Airtable personal access token configured' })
    return
  end

  local curl = require 'plenary.curl'
  local records = {}
  local path = build_path()

  ---@param offset string?
  local function fetch_page(offset)
    curl.get(path, {
      query = build_query(formula, sort, offset),
      headers = { Authorization = 'Bearer ' .. token },
      -- Disable curl's URL globbing ("-g"): without it, curl interprets literal
      -- "[" / "]" in `sort[0][field]`-style query keys as its own range/glob syntax
      -- and fails with "bad range in URL" instead of sending the request.
      raw = { '-g' },
      callback = vim.schedule_wrap(function(response)
        if response.status ~= 200 then
          callback(nil, {
            category = string.format('API Error (%d)', response.status),
            message = response.body or 'no response body',
          })
          return
        end

        local ok, decoded = pcall(vim.json.decode, response.body)
        if not ok then
          callback(nil, { category = 'Response Error', message = 'failed to decode Airtable response' })
          return
        end

        vim.list_extend(records, decoded.records or {})

        if decoded.offset then
          fetch_page(decoded.offset)
        else
          callback(records, nil)
        end
      end),
    })
  end

  fetch_page(nil)
end

return M
