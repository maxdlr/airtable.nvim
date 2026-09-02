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

---Builds the request URL for listing records, including the filter formula and pagination offset.
---@param formula string
---@param offset string?
---@return string
local function build_url(formula, offset)
  local opts = config.options
  local params = {
    'filterByFormula=' .. vim.uri_encode(formula),
    'pageSize=' .. tostring(opts.page_size),
  }
  if offset then table.insert(params, 'offset=' .. vim.uri_encode(offset)) end
  return string.format('%s/%s/%s?%s', API_URL, opts.base_id, vim.uri_encode(opts.table_name), table.concat(params, '&'))
end

---Fetches every page of records matching `formula` from Airtable.
---@param formula string
---@param callback fun(records: AirtableRecord[]?, err: AirtableError?)
function M.list_records(formula, callback)
  local token = config.token()
  if not token then
    callback(nil, { category = 'Missing Token', message = 'no Airtable personal access token configured' })
    return
  end

  local curl = require 'plenary.curl'
  local records = {}

  ---@param offset string?
  local function fetch_page(offset)
    curl.get(build_url(formula, offset), {
      headers = { Authorization = 'Bearer ' .. token },
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
