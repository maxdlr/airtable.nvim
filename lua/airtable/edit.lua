local api = require 'airtable.api'
local notify = require('airtable.notify').notify

local M = {}

---Opens a Telescope picker listing `field`'s valid choices (fetched from Airtable's
---metadata). Selecting one with `<CR>` PATCHes the record and calls `on_updated(record)`.
---@param record_id string
---@param field string Airtable field name
---@param on_updated fun(record: AirtableRecord)
function M.edit_select(record_id, field, on_updated)
  api.get_field_choices(field, function(choices, err)
    if err then
      notify(err.category, err.message, vim.log.levels.ERROR)
      return
    end
    if #choices == 0 then
      notify('No Choices', string.format('field "%s" has no configured choices', field), vim.log.levels.INFO)
      return
    end

    local pickers = require 'telescope.pickers'
    local finders = require 'telescope.finders'
    local conf = require('telescope.config').values
    local actions = require 'telescope.actions'
    local action_state = require 'telescope.actions.state'

    pickers
      .new({}, {
        prompt_title = 'Edit ' .. field,
        finder = finders.new_table { results = choices },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr, map)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selection then return end

            api.update_record(record_id, field, selection[1], function(record, update_err)
              if update_err then
                notify(update_err.category, update_err.message, vim.log.levels.ERROR)
                return
              end
              notify('Updated', string.format('%s set to "%s"', field, selection[1]), vim.log.levels.INFO)
              on_updated(record)
            end)
          end)
          return true
        end,
      })
      :find()
  end)
end

---Opens a small centered floating scratch buffer prefilled with `current_value`. The
---buffer is `acwrite` (Neovim will call a `BufWriteCmd` instead of writing to disk), so
---`<C-CR>` (primary) or `:w`/`:wa` PATCHes the field to the buffer's content instead of
---saving a file. `:q` discards the changes without saving.
---@param record_id string
---@param field string Airtable field name
---@param current_value string
---@param on_updated fun(record: AirtableRecord)
function M.edit_text(record_id, field, current_value, on_updated)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(current_value, '\n', { plain = true }))
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_name(buf, 'airtable-edit://' .. record_id .. '/' .. field)

  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local height = math.min(20, math.floor(vim.o.lines * 0.4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = string.format(' Edit %s (<C-CR> or :w to save, :q to cancel) ', field),
    title_pos = 'center',
    style = 'minimal',
  })

  -- <C-CR> is the primary "confirm and save" keymap; :w/:wa keep working too since both
  -- go through the same BufWriteCmd below.
  vim.keymap.set({ 'n', 'i' }, '<C-CR>', '<cmd>write<cr>', { buffer = buf, desc = 'Save edit' })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local new_value = table.concat(lines, '\n')

      api.update_record(record_id, field, new_value, function(record, err)
        if err then
          notify(err.category, err.message, vim.log.levels.ERROR)
          return
        end
        -- Clear the "modified" flag so :q doesn't warn about unsaved changes, and
        -- close the floating window now that the save succeeded.
        vim.bo[buf].modified = false
        notify('Updated', string.format('%s saved', field), vim.log.levels.INFO)
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        on_updated(record)
      end)
    end,
  })
end

return M
