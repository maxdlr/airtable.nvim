local api = require 'airtable.api'
local notify = require('airtable.notify').notify

local M = {}

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

-- buftype=nofile (not acwrite): deliberately not wired to :w/:wa/BufWriteCmd, so
-- auto-save plugins reacting to InsertLeave/TextChanged/BufLeave can't trigger a
-- premature save. <C-CR> is the only way to save; :q discards changes.
function M.edit_text(record_id, field, current_value, on_updated)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(current_value, '\n', { plain = true }))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_name(buf, 'airtable-edit://' .. record_id .. '/' .. field)

  local width = math.min(120, math.floor(vim.o.columns * 0.8))
  local height = math.min(35, math.floor(vim.o.lines * 0.7))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = string.format(' Edit %s (<C-CR> to save, :q to cancel) ', field),
    title_pos = 'center',
    style = 'minimal',
  })

  local function save()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local new_value = table.concat(lines, '\n')

    api.update_record(record_id, field, new_value, function(record, err)
      if err then
        notify(err.category, err.message, vim.log.levels.ERROR)
        return
      end
      notify('Updated', string.format('%s saved', field), vim.log.levels.INFO)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      on_updated(record)
    end)
  end

  vim.keymap.set({ 'n', 'i' }, '<C-CR>', save, { buffer = buf, desc = 'Save edit' })
end

return M
