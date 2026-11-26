-- Editable regions of a record buffer, tracked by range extmarks so they follow the
-- user's edits. The start mark sticks left and the end mark sticks right, so text
-- typed at either edge (including `o`/`O` on a block's first/last line) stays inside.
--
-- Everything outside the regions is "static": it must never change. Neovim has no
-- read-only ranges, so view.lua gates 'modifiable' on cursor position and uses
-- `static_text` as a backstop for edits that cross a boundary (e.g. `dG`).

local M = {}

M.NS = vim.api.nvim_create_namespace("airtable_regions")
M.DECOR_NS = vim.api.nvim_create_namespace("airtable_region_decor")

---@class AirtableRegion : AirtableRegionSpec
---@field mark integer extmark id in M.NS

---@param buf integer
---@param specs AirtableRegionSpec[]
---@return AirtableRegion[]
function M.attach(buf, specs)
	vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
	local regions = {}
	for _, spec in ipairs(specs) do
		local region = vim.deepcopy(spec)
		region.mark = vim.api.nvim_buf_set_extmark(buf, M.NS, spec.start_row, spec.start_col, {
			end_row = spec.end_row,
			end_col = spec.end_col,
			right_gravity = false,
			end_right_gravity = true,
		})
		table.insert(regions, region)
	end
	return regions
end

---@return integer start_row, integer start_col, integer end_row, integer end_col
function M.range(buf, region)
	local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS, region.mark, { details = true })
	return mark[1], mark[2], mark[3].end_row, mark[3].end_col
end

local function set_range(buf, region, sr, sc, er, ec)
	vim.api.nvim_buf_set_extmark(buf, M.NS, sr, sc, {
		id = region.mark,
		end_row = er,
		end_col = ec,
		right_gravity = false,
		end_right_gravity = true,
	})
end

---@return integer[][] ranges Current range of each region, for `restore_ranges`
function M.snapshot(buf, regions)
	local ranges = {}
	for i, region in ipairs(regions) do
		ranges[i] = { M.range(buf, region) }
	end
	return ranges
end

function M.restore_ranges(buf, regions, ranges)
	for i, region in ipairs(regions) do
		set_range(buf, region, unpack(ranges[i]))
	end
end

-- Deleting a block's last line (`dd`) drags its end mark onto col 0 of the following
-- line, swallowing a line break that belongs to the static text after it. Pulls the
-- end back to the end of the previous line.
-- Only a repair attempt: a value ending in "\n" legitimately ends at col 0 of its
-- last (empty) line, so callers must check the static text still matches after this.
function M.normalize(buf, regions)
	for _, region in ipairs(regions) do
		if region.kind == "block" then
			local sr, sc, er, ec = M.range(buf, region)
			if ec == 0 and er > sr then
				local prev = vim.api.nvim_buf_get_lines(buf, er - 1, er, false)[1] or ""
				set_range(buf, region, sr, sc, er - 1, #prev)
			end
		end
	end
end

-- Whole lines added next to a region (`o` / insert-mode <CR> on its last line, `O` on
-- a block's first line, linewise `p`/`P`) are appended as lines, not as a line break
-- inside the extmark, so they land just outside it. Pull them in, but only when doing
-- so makes the static text exactly what it was: then they can only be the user's.
---@param expected_static string
---@param added integer Lines added since `expected_static` was taken
---@return boolean absorbed
function M.absorb(buf, regions, expected_static, added)
	if added <= 0 then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	for _, region in ipairs(regions) do
		if not region.single_line then
			local sr, sc, er, ec = M.range(buf, region)
			if er + added < line_count then
				local last = vim.api.nvim_buf_get_lines(buf, er + added, er + added + 1, false)[1] or ""
				set_range(buf, region, sr, sc, er + added, #last)
				if M.static_text(buf, regions) == expected_static then
					return true
				end
				set_range(buf, region, sr, sc, er, ec)
			end
			if region.kind == "block" and sr - added >= 0 then
				set_range(buf, region, sr - added, 0, er, ec)
				if M.static_text(buf, regions) == expected_static then
					return true
				end
				set_range(buf, region, sr, sc, er, ec)
			end
		end
	end
	return false
end

---@return string
function M.text(buf, region)
	local sr, sc, er, ec = M.range(buf, region)
	local ok, parts = pcall(vim.api.nvim_buf_get_text, buf, sr, sc, er, ec, {})
	if not ok then
		return ""
	end
	return table.concat(parts, "\n")
end

---@return table<string, string> field -> current buffer text
function M.values(buf, regions)
	local values = {}
	for _, region in ipairs(regions) do
		values[region.field] = M.text(buf, region)
	end
	return values
end

local function sorted_ranges(buf, regions)
	local ranges = {}
	for _, region in ipairs(regions) do
		local sr, sc, er, ec = M.range(buf, region)
		table.insert(ranges, { sr, sc, er, ec })
	end
	table.sort(ranges, function(a, b)
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	return ranges
end

-- The buffer's text with every region cut out, pieces joined by "\0". Compared before
-- and after a change to detect edits to static text. nil if regions overlap or are out
-- of order (only possible after a boundary-crossing edit, so also a violation).
---@return string?
function M.static_text(buf, regions)
	local pieces = {}
	local row, col = 0, 0
	for _, r in ipairs(sorted_ranges(buf, regions)) do
		if r[1] < row or (r[1] == row and r[2] < col) then
			return nil
		end
		table.insert(pieces, table.concat(vim.api.nvim_buf_get_text(buf, row, col, r[1], r[2], {}), "\n"))
		row, col = r[3], r[4]
	end
	local last_row = vim.api.nvim_buf_line_count(buf) - 1
	local last_line = vim.api.nvim_buf_get_lines(buf, last_row, last_row + 1, false)[1] or ""
	if row > last_row or (row == last_row and col > #last_line) then
		return nil
	end
	table.insert(pieces, table.concat(vim.api.nvim_buf_get_text(buf, row, col, last_row, #last_line, {}), "\n"))
	return table.concat(pieces, "\0")
end

-- Region containing a 0-based (row, col). The end is inclusive so the insert-mode
-- cursor sitting just past the last character still counts as inside.
---@return AirtableRegion?
function M.at(buf, regions, row, col)
	for _, region in ipairs(regions) do
		local sr, sc, er, ec = M.range(buf, region)
		local after_start = row > sr or (row == sr and col >= sc)
		local before_end = row < er or (row == er and col <= ec)
		if after_start and before_end then
			return region
		end
	end
	return nil
end

---@param region AirtableRegion
---@return boolean
function M.is_at_start(buf, region, row, col)
	local sr, sc = M.range(buf, region)
	return row == sr and col == sc
end

---@param region AirtableRegion
---@return boolean
function M.is_at_end(buf, region, row, col)
	local _, _, er, ec = M.range(buf, region)
	return row == er and col == ec
end

-- Decorations that depend on a region's current extent: left borders on every row of
-- a block (new rows from `o` need one too), text highlight, and the empty placeholder.
-- Cheap enough to redraw after every change.
function M.decorate(buf, regions)
	vim.api.nvim_buf_clear_namespace(buf, M.DECOR_NS, 0, -1)
	for _, region in ipairs(regions) do
		local sr, sc, er, ec = M.range(buf, region)
		if region.border then
			for row = sr, er do
				pcall(vim.api.nvim_buf_set_extmark, buf, M.DECOR_NS, row, 0, {
					virt_text = { region.border },
					virt_text_pos = "inline",
					right_gravity = false,
				})
			end
		end
		if region.hl and (er > sr or ec > sc) then
			pcall(vim.api.nvim_buf_set_extmark, buf, M.DECOR_NS, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = region.hl,
			})
		end
		if sr == er and sc == ec then
			pcall(vim.api.nvim_buf_set_extmark, buf, M.DECOR_NS, sr, sc, {
				virt_text = { { region.placeholder or "", "Comment" } },
				virt_text_pos = "eol",
			})
		end
	end
end

return M
