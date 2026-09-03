local api = require 'airtable.api'
local notify = require('airtable.notify').notify

local M = {}

---Builds a one-line preview for a comment: author name, then the comment text with
---newlines flattened to spaces so it fits on a single result line.
---@param comment table
---@return string
local function comment_preview(comment)
  local author = comment.author and comment.author.name or 'Unknown'
  local text = (comment.text or ''):gsub('\n', ' ')
  return string.format('%s: %s', author, text)
end

---Opens a Telescope picker listing `record_id`'s comments. Airtable's API does not expose
---a per-comment permalink, so selecting a comment copies the record's URL instead (the
---record's comments panel is visible from there) and closes the picker.
---@param record_id string
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
