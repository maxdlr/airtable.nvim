-- Pill/bubble rendering: wraps text in rounded-cap glyphs whose foreground matches the
-- body's background, creating a pill shape out of colored text. Same technique as
-- octo.nvim's make_bubble.

local colors = require 'airtable.colors'

local M = {}

-- Powerline rounded caps (U+E0B6/U+E0B4), as explicit UTF-8 byte escapes so the
-- codepoint survives regardless of editor/terminal encoding.
local LEFT_CAP = '\238\130\182'
local RIGHT_CAP = '\238\130\180'

---@param text string
---@param bg_hex string Hex background color for the pill body (e.g. "#7aa2f7")
---@return { [1]: string, [2]: string }[] chunks
function M.make_bubble(text, bg_hex)
  local ok, chunks = pcall(function()
    local body_hl = colors.create_highlight(bg_hex)
    local cap_hl = colors.create_foreground_highlight(bg_hex)
    local body = ' ' .. text .. ' '
    return {
      { LEFT_CAP, cap_hl },
      { body, body_hl },
      { RIGHT_CAP, cap_hl },
    }
  end)
  if ok then return chunks end
  return { { ' ' .. text .. ' ', 'Normal' } }
end

return M
