-- Highlight-group utilities for pill/bubble styling. Every public function here is
-- wrapped so a broken colorscheme, a missing highlight group, or any other unexpected
-- failure degrades to a safe fallback instead of throwing and breaking the buffer render.

local M = {}

local HIGHLIGHT_PREFIX = 'AirtablePill'
local highlight_cache = {} ---@type table<string, string>

---A small, curated palette used when no explicit color is available (deterministic
---hashing, see `M.color_for_value`). Colors are hex so they compose with any colorscheme;
---`create_highlight` picks a readable foreground automatically.
local FALLBACK_PALETTE = {
  '#7aa2f7', -- blue
  '#9ece6a', -- green
  '#e0af68', -- yellow
  '#f7768e', -- red
  '#bb9af7', -- purple
  '#7dcfff', -- cyan
  '#ff9e64', -- orange
}

---Returns the given highlight group's background color as "#rrggbb", falling back to
---"Normal"'s background, or nil if neither resolves (e.g. no colors set at all).
---@param highlight_group string
---@return string?
function M.get_background_color_of_highlight_group(highlight_group)
  local ok, result = pcall(function()
    local hl = vim.api.nvim_get_hl(0, { name = highlight_group, link = false })
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    local bg = hl.bg or normal.bg
    if bg then return string.format('#%06x', bg) end
    return nil
  end)
  if ok then return result end
  return nil
end

---Perceptive luminance check (human eye favors green) to decide whether a background
---color needs a black or white foreground for readability.
---@param r integer
---@param g integer
---@param b integer
---@return boolean bright
local function is_bright(r, g, b)
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5
end

---Creates (or returns the cached) highlight group for a hex background color, with an
---automatically chosen readable foreground (black on light backgrounds, white on dark).
---Returns "Normal" if `hex` is malformed or highlight creation fails for any reason —
---this function is not allowed to throw.
---@param hex string e.g. "#7aa2f7"
---@return string highlight_group
function M.create_highlight(hex)
  local ok, result = pcall(function()
    local normalized = hex:lower():gsub('^#', '')
    if not normalized:match('^%x%x%x%x%x%x$') then error('not a hex color: ' .. tostring(hex)) end

    local cache_key = normalized
    local cached = highlight_cache[cache_key]
    if cached then return cached end

    local r = tonumber(normalized:sub(1, 2), 16)
    local g = tonumber(normalized:sub(3, 4), 16)
    local b = tonumber(normalized:sub(5, 6), 16)
    local fg = is_bright(r, g, b) and '#000000' or '#ffffff'

    local group = HIGHLIGHT_PREFIX .. normalized
    vim.api.nvim_set_hl(0, group, { fg = fg, bg = '#' .. normalized })
    highlight_cache[cache_key] = group
    return group
  end)
  if ok and result then return result end
  return 'Normal'
end

---Creates (or returns the cached) highlight group that renders `hex` as a foreground
---color only (no background) — used for pill delimiter glyphs, which need to match the
---pill body's background color as their own foreground to create the rounded-cap illusion.
---Returns "Normal" on any failure.
---@param hex string
---@return string highlight_group
function M.create_foreground_highlight(hex)
  local ok, result = pcall(function()
    local normalized = hex:lower():gsub('^#', '')
    if not normalized:match('^%x%x%x%x%x%x$') then error('not a hex color: ' .. tostring(hex)) end

    local cache_key = 'fg_' .. normalized
    local cached = highlight_cache[cache_key]
    if cached then return cached end

    local group = HIGHLIGHT_PREFIX .. 'Fg' .. normalized
    vim.api.nvim_set_hl(0, group, { fg = '#' .. normalized })
    highlight_cache[cache_key] = group
    return group
  end)
  if ok and result then return result end
  return 'Normal'
end

---Deterministically picks a color for `value` from a small fallback palette, so the same
---text (e.g. the same Airtable select option) always renders with the same color across
---records, without needing per-value configuration or an extra API call to fetch
---Airtable's real field colors.
---@param value string
---@return string hex
function M.color_for_value(value)
  local ok, result = pcall(function()
    local hash = 0
    for i = 1, #value do
      hash = (hash * 31 + value:byte(i)) % 2147483647
    end
    local index = (hash % #FALLBACK_PALETTE) + 1
    return FALLBACK_PALETTE[index]
  end)
  if ok and result then return result end
  return FALLBACK_PALETTE[1]
end

return M
