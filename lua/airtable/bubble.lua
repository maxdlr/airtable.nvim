-- Pill/bubble rendering: wraps a piece of text in rounded-cap delimiter glyphs whose
-- foreground color matches the body's background, creating the illusion of a rounded
-- pill shape entirely out of colored text (no actual shapes/images involved). Matches
-- the technique used by octo.nvim's `make_bubble`.

local colors = require 'airtable.colors'

local M = {}

-- Powerline-style rounded caps, available in any Nerd Font. If the user's font lacks
-- them, they'll render as tofu/blank glyphs — a font issue, not a plugin crash.
local LEFT_CAP = ''
local RIGHT_CAP = ''

---Builds the three `{ text, highlight }` chunks that make up a pill: a left cap, the
---padded body, and a right cap. Intended to be written into a buffer via
---`nvim_buf_set_extmark`'s `virt_text` (each chunk becomes one `[text, hl]` pair) or
---concatenated as plain text with per-chunk highlight ranges — see `airtable.view`.
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
  -- Fallback: plain, unstyled text — still renders something readable rather than
  -- breaking the buffer if highlight creation fails for any reason.
  return { { ' ' .. text .. ' ', 'Normal' } }
end

return M
