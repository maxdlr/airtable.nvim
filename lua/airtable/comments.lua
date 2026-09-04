local api = require 'airtable.api'
local notify = require('airtable.notify').notify

local M = {}

-- Replaces @[user_id] mention tokens with @DisplayName via the comment's own
-- `mentioned` map. Unknown ids (e.g. deleted collaborator) are left as-is.
local function resolve_mentions(text, mentioned)
  if not mentioned then return text end
  return (text:gsub('@%[([%w]+)%]', function(user_id)
    local user = mentioned[user_id]
    if user and user.displayName then return '@' .. user.displayName end
    return '@[' .. user_id .. ']'
  end))
end

local function comment_preview(comment)
  local author = comment.author and comment.author.name or 'Unknown'
  local text = resolve_mentions(comment.text or '', comment.mentioned):gsub('\n', ' ')
  return string.format('%s: %s', author, text)
end

local function comment_lines(comment)
  local author = comment.author and comment.author.name or 'Unknown'
  local created_at = comment.createdTime or ''
  local lines = { string.format('# %s', author) }
  if created_at ~= '' then
    table.insert(lines, created_at)
  end
  table.insert(lines, '')
  local text = resolve_mentions(comment.text or '', comment.mentioned)
  vim.list_extend(lines, vim.split(text, '\n', { plain = true }))
  return lines
end

local function make_previewer()
  local previewers = require 'telescope.previewers'
  return previewers.new_buffer_previewer {
    title = 'Comment',
    define_preview = function(self, entry)
      local lines = comment_lines(entry.value)
      vim.bo[self.state.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = 'markdown'
      vim.bo[self.state.bufnr].modifiable = false
      vim.bo[self.state.bufnr].buftype = 'nofile'
    end,
  }
end

-- Airtable has no per-comment permalink, so selecting one copies the record's URL instead.
function M.pick(record_id)
  api.list_record_comments(record_id, function(comments, err)
    if err then
      notify(err.category, err.message, vim.log.levels.ERROR)
      return
    end
    if #comments == 0 then
      notify('No Comments', 'this record has no comments', vim.log.levels.INFO)
      return
    end

    local pickers = require 'telescope.pickers'
    local finders = require 'telescope.finders'
    local conf = require('telescope.config').values
    local actions = require 'telescope.actions'
    local action_state = require 'telescope.actions.state'

    pickers
      .new({}, {
        prompt_title = 'Comments',
        finder = finders.new_table {
          results = comments,
          entry_maker = function(comment)
            return {
              value = comment,
              display = comment_preview(comment),
              ordinal = comment_preview(comment),
            }
          end,
        },
        sorter = conf.generic_sorter {},
        previewer = make_previewer(),
        attach_mappings = function(prompt_bufnr, map)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            api.record_url(record_id, function(url, url_err)
              if url_err then
                notify(url_err.category, url_err.message, vim.log.levels.ERROR)
                return
              end
              vim.fn.setreg('+', url)
              notify('Copied', 'record URL copied to clipboard', vim.log.levels.INFO)
            end)
          end)
          return true
        end,
      })
      :find()
  end)
end

return M
