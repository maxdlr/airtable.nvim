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

---@param ctx snacks.picker.preview.ctx
local function preview_comment(ctx)
  ctx.preview:reset()
  ctx.preview:set_lines(comment_lines(ctx.item.comment))
  ctx.preview:set_title('Comment')
  vim.bo[ctx.buf].filetype = 'markdown'
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

    local items = {}
    for _, comment in ipairs(comments) do
      table.insert(items, { text = comment_preview(comment), comment = comment })
    end

    Snacks.picker.pick({
      title = 'Comments',
      items = items,
      format = function(item)
        return { { item.text, 'Normal' } }
      end,
      preview = preview_comment,
      confirm = function(picker)
        picker:close()
        api.record_url(record_id, function(url, url_err)
          if url_err then
            notify(url_err.category, url_err.message, vim.log.levels.ERROR)
            return
          end
          vim.fn.setreg('+', url)
          notify('Copied', 'record URL copied to clipboard', vim.log.levels.INFO)
        end)
      end,
    })
  end)
end

return M
