-- Highlight-group utilities for pill/bubble styling. Every public function is
-- pcall-guarded so it degrades to a safe fallback instead of breaking the render.

local M = {}

local HIGHLIGHT_PREFIX = 'AirtablePill'
local highlight_cache = {} ---@type table<string, string>

-- Fallback palette used when hashing a value deterministically (see color_for_value).
local FALLBACK_PALETTE = {
  '#7aa2f7', '#9ece6a', '#e0af68', '#f7768e', '#bb9af7', '#7dcfff', '#ff9e64',
}

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

local function is_bright(r, g, b)
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5
end

-- Auto-picks black/white foreground for readability. Returns "Normal" on any failure.
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

-- Foreground-only variant, used for pill cap glyphs so they match the pill body's
-- background and create the rounded-cap illusion. Returns "Normal" on failure.
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

-- Deterministic hash so the same value always gets the same color, with no config
-- or extra API call needed.
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
