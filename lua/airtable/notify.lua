local M = {}

---Sends a toast notification with a title reflecting the error/message category
---(e.g. "Airtable · Config Error") and the actual detail as the notification body.
---@param category string Short category shown in the title, e.g. "Config Error"
---@param message string
---@param level integer vim.log.levels.*
---@param opts table? Extra vim.notify options, e.g. `id` to replace a previous toast
function M.notify(category, message, level, opts)
  vim.notify(message, level, vim.tbl_extend('force', opts or {}, { title = 'Airtable · ' .. category }))
end

return M
