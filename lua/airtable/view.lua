local config = require("airtable.config")
local notify = require("airtable.notify").notify
local api = require("airtable.api")
local format_field = api.format_field
local style = require("airtable.style")
local colors = require("airtable.colors")
local bubble = require("airtable.bubble")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("airtable_view")

-- Left-border bar character used to decorate "plain" sections, echoing the vertical
-- border seen in tools like octo.nvim/gitsigns. A plain buffer-text character (not a
-- sign/statuscolumn), so it works identically in a real buffer and in Telescope's
-- previewer without touching window-local options.
local LEFT_BORDER = "▌"
local LEFT_BORDER_HL = "Comment"

---Builds one pill line's `virt_text` overlay chunks (heading label + colored pill),
---falling back to plain text if anything goes wrong.
---@param heading string
---@param text string
---@return { [1]: string, [2]: string }[]
local function pill_line_chunks(heading, text)
  -- An empty/absent value isn't really a "status" to badge — render it as a plain,
  -- dim label instead of wrapping the "_Empty._" placeholder in a colored pill.
  if text == "_Empty._" then
    return { { heading .. ': ', 'Title' }, { text, 'Comment' } }
  end

  local ok, chunks = pcall(function()
    local hex = colors.color_for_value(text)
    local pill_chunks = bubble.make_bubble(text, hex)
    local result = { { heading .. ' ', 'Title' } }
    vim.list_extend(result, pill_chunks)
    return result
  end)
  if ok then return chunks end
  return { { heading .. ': ' .. text, 'Normal' } }
end

---Builds the markdown lines + extmark specs for a record from `buffer.fields`. The
---`title` key (if configured) becomes the H1 heading; every other key becomes its own
---section, styled by `airtable.style.classify(key)`:
---  - 'heading': rendered like a sub-heading, bold/emphasized text, no border/pill.
---  - 'pill': the key label plus the value rendered as a colored pill/bubble.
---  - 'plain': a left-border bar character on each line of the body text.
---@param record AirtableRecord
---@param opts { exclude: table<string, boolean>?, skip_missing: boolean? }? `exclude`:
---  set of `buffer.fields` keys to omit entirely (e.g. fields already shown in a picker's
---  `result_line`). `skip_missing`: when true, a field absent from `record.fields` is
---  omitted instead of rendered as "_Empty._" — used for previews built from list data,
---  where a field's absence just means it wasn't fetched, not that it's actually empty.
---@return string[] lines
---@return { line: integer, col: integer, opts: table }[] extmarks
local function render_buffer(record, opts)
  opts = opts or {}
  local exclude = opts.exclude or {}
  local fields = config.options.buffer.fields
  local title = fields.title and format_field(record.fields[fields.title]) or ""
  if title == "" then
    title = "(untitled)"
  end

  local lines = { "# " .. title, "" }
  local extmarks = {}

  -- pairs() iteration order isn't guaranteed for string keys; sort alphabetically so
  -- section order is stable across runs. (If explicit ordering matters, this can be
  -- revisited to use an ordered list instead of a plain table for `fields`.)
  local other_keys = {}
  for key in pairs(fields) do
    if key ~= "title" and not exclude[key] then
      table.insert(other_keys, key)
    end
  end
  table.sort(other_keys)

  for _, key in ipairs(other_keys) do
    local field_name = fields[key]
    local raw_value = record.fields[field_name]
    if raw_value == nil and opts.skip_missing then
      goto continue
    end

    local text = format_field(raw_value)
    if text == "" then
      text = "_Empty._"
    end
    local heading = key:sub(1, 1):upper() .. key:sub(2)
    local section_style = style.classify(key)

    if section_style == "pill" then
      table.insert(lines, "")
      local line_idx = #lines -- 0-based index of the line about to be appended below
      table.insert(lines, "")
      table.insert(extmarks, {
        line = line_idx,
        col = 0,
        opts = { virt_text = pill_line_chunks(heading, text), virt_text_pos = "overlay" },
      })
      table.insert(lines, "")
    elseif section_style == "heading" then
      table.insert(lines, "")
      table.insert(lines, heading .. ": " .. text)
      table.insert(extmarks, {
        line = #lines - 1,
        col = 0,
        opts = { hl_group = "Title", end_col = #(heading .. ": " .. text) },
      })
      table.insert(lines, "")
    else
      vim.list_extend(lines, { "## " .. heading, "" })
      for _, body_line in ipairs(vim.split(text, "\n", { plain = true })) do
        table.insert(lines, body_line)
        table.insert(extmarks, {
          line = #lines - 1,
          col = 0,
          opts = {
            virt_text = { { LEFT_BORDER, LEFT_BORDER_HL } },
            virt_text_pos = "inline",
          },
        })
      end
      table.insert(lines, "")
    end

    ::continue::
  end

  return lines, extmarks
end
M.render_buffer = render_buffer

---Applies a list of extmark specs (as returned by `render_buffer`) to `buf`. Each
---extmark's placement is individually pcall-guarded so one bad spec (e.g. an out-of-range
---line after unrelated edits) can't take down the rest of the render.
---@param buf integer
---@param extmarks { line: integer, col: integer, opts: table }[]
function M.apply_extmarks(buf, extmarks)
  for _, mark in ipairs(extmarks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, M.NAMESPACE, mark.line, mark.col, mark.opts)
  end
end

---Opens `vim.ui.select` with the record's available actions: open in browser, browse
---comments, or copy the record URL.
---@param record_id string
local function open_context_menu(record_id)
	local items = {
		'Open in browser',
		'Browse comments',
		'Copy record URL',
	}

	vim.ui.select(items, { prompt = 'Airtable record' }, function(choice)
		if not choice then
			return
		end

		if choice == 'Open in browser' then
			api.record_url(record_id, function(url, err)
				if err then
					notify(err.category, err.message, vim.log.levels.ERROR)
					return
				end
				vim.ui.open(url)
			end)
		elseif choice == 'Browse comments' then
			require("airtable.comments").pick(record_id)
		elseif choice == 'Copy record URL' then
			api.record_url(record_id, function(url, err)
				if err then
					notify(err.category, err.message, vim.log.levels.ERROR)
					return
				end
				vim.fn.setreg("+", url)
				notify("Copied", "record URL copied to clipboard", vim.log.levels.INFO)
			end)
		end
	end)
end

---Finds the URL under the cursor on the current line, if any. Scans the line for
---`http(s)://`-prefixed spans and returns the one containing the cursor column.
---@return string?
local function url_under_cursor()
	local ok, result = pcall(function()
		local line = vim.api.nvim_get_current_line()
		local cursor_col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte column
		for start_col, url in line:gmatch("()(https?://[^%s%)%]>\"']+)") do
			local end_col = start_col + #url - 1
			if cursor_col >= start_col - 1 and cursor_col <= end_col - 1 then
				return url
			end
		end
		return nil
	end)
	if ok then return result end
	return nil
end

---Opens a non-writable scratch buffer showing the record formatted as markdown. If a
---buffer for this record is already open (e.g. in another tab), it's closed first —
---buffer names must be unique, and `nvim_buf_set_name` would otherwise error with
---"buffer already exists" when reopening the same record.
---@param record_id string
function M.open(record_id)
	api.get_recordById(record_id, function(record, err)
		if err then
			notify(err.category, err.message, vim.log.levels.ERROR)
			return
		end
		if not record then
			notify("No Record", string.format('no record found for id "%s"', record_id), vim.log.levels.INFO)
			return
		end

		local buf_name = "airtable://" .. record.id
		local existing_buf = vim.fn.bufnr(buf_name)
		if existing_buf ~= -1 then
			pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
		end

		local buf = vim.api.nvim_create_buf(false, true)
		local lines, extmarks = render_buffer(record)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		M.apply_extmarks(buf, extmarks)

		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.api.nvim_buf_set_name(buf, buf_name)

		vim.keymap.set("n", "<CR>", function()
			open_context_menu(record.id)
		end, { buffer = buf, desc = "Airtable record actions" })

		vim.keymap.set("n", "o", function()
			local url = url_under_cursor()
			if not url then
				notify("No URL", "no URL under cursor", vim.log.levels.INFO)
				return
			end
			vim.ui.open(url)
		end, { buffer = buf, desc = "Open URL under cursor" })

		vim.keymap.set("n", "c", function()
			local url = url_under_cursor()
			if not url then
				notify("No URL", "no URL under cursor", vim.log.levels.INFO)
				return
			end
			vim.fn.setreg("+", url)
			notify("Copied", "URL copied to clipboard", vim.log.levels.INFO)
		end, { buffer = buf, desc = "Copy URL under cursor" })

		vim.api.nvim_set_current_buf(buf)
	end)
end

return M
