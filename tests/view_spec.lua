local helpers = require("tests.helpers")
local api = require("airtable.api")
local view = require("airtable.view")
local regions = require("airtable.regions")

local RECORD_FIELDS = { Title = "Fix login", Status = "Todo", Description = "Line 1\nLine 2", Estimate = 3 }

describe("record buffer", function()
	local calls, restore_api, notified, restore_notify, server

	local function open()
		view.open("recTEST1")
		assert.is_true(helpers.wait_for(function()
			return view.session(vim.api.nvim_get_current_buf()) ~= nil
		end))
		return view.session(vim.api.nvim_get_current_buf())
	end

	local function region(session, field)
		for _, r in ipairs(session.regions) do
			if r.field == field then
				return r
			end
		end
	end

	local function changed(buf)
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	end

	local function cursor(row, col)
		vim.api.nvim_win_set_cursor(0, { row + 1, col })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
	end

	before_each(function()
		helpers.setup()
		notified, restore_notify = helpers.capture_notifications()
		calls = {}
		server = helpers.record(vim.deepcopy(RECORD_FIELDS))
		restore_api = helpers.stub(api, {
			get_field_types = function(cb)
				cb(helpers.FIELD_TYPES, nil)
			end,
			get_recordById = function(_, cb)
				cb(vim.deepcopy(server), nil)
			end,
			update_record = function(record_id, fields, callback)
				table.insert(calls, { fields = fields, sync = callback == nil })
				server.fields = vim.tbl_extend("force", server.fields, fields)
				if callback then
					vim.schedule(function()
						callback(vim.deepcopy(server), nil)
					end)
					return
				end
				return vim.deepcopy(server), nil
			end,
		})
	end)

	after_each(function()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if view.session(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
		restore_api()
		restore_notify()
	end)

	it("opens an acwrite markdown buffer with the record rendered", function()
		local session = open()
		local buf = session.buf
		assert.are.equal("acwrite", vim.bo[buf].buftype)
		assert.are.equal("markdown", vim.bo[buf].filetype)
		assert.are.equal("# Fix login", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
		assert.is_false(vim.bo[buf].modified)
		assert.matches("airtable://Fix login$", vim.api.nvim_buf_get_name(buf))
	end)

	it("is only modifiable while the cursor is inside an editable field", function()
		local session = open()
		cursor(5, 0) -- "## Description"
		assert.is_false(vim.bo[session.buf].modifiable)
		cursor(7, 2) -- description body
		assert.is_true(vim.bo[session.buf].modifiable)
		cursor(0, 0) -- "#" of the title
		assert.is_false(vim.bo[session.buf].modifiable)
		cursor(0, 4) -- title text
		assert.is_true(vim.bo[session.buf].modifiable)
	end)

	it("autosaves edits typed into the buffer after the debounce", function()
		local session = open()
		cursor(8, 6)
		vim.api.nvim_buf_set_text(session.buf, 8, 6, 8, 6, { "", "Line 3" })
		changed(session.buf)
		assert.is_true(vim.bo[session.buf].modified)

		assert.is_true(helpers.wait_for(function()
			return #calls == 1 and not vim.bo[session.buf].modified
		end))
		assert.are.same({ Description = "Line 1\nLine 2\nLine 3" }, calls[1].fields)
	end)

	it("reverts edits to read-only text but keeps field edits", function()
		local session = open()
		cursor(0, 10)
		vim.api.nvim_buf_set_text(session.buf, 0, 11, 0, 11, { "!" })
		vim.bo[session.buf].modifiable = true
		vim.api.nvim_buf_set_lines(session.buf, 5, 6, false, { "## Hacked" })
		changed(session.buf)

		assert.is_true(helpers.wait_for(function()
			return vim.api.nvim_buf_get_lines(session.buf, 5, 6, false)[1] == "## Description"
		end))
		assert.are.equal("# Fix login!", vim.api.nvim_buf_get_lines(session.buf, 0, 1, false)[1])
		assert.matches("change reverted", notified[#notified].message)
		assert.is_true(helpers.wait_for(function()
			return #calls == 1
		end))
		assert.are.same({ Title = "Fix login!" }, calls[1].fields)
	end)

	it("restores structure when a single-line field gets a line break (paste)", function()
		local session = open()
		cursor(0, 10)
		vim.api.nvim_buf_set_text(session.buf, 0, 11, 0, 11, { "", "pasted" })
		changed(session.buf)
		assert.is_true(helpers.wait_for(function()
			return vim.api.nvim_buf_get_lines(session.buf, 0, 1, false)[1] == "# Fix login pasted"
		end))
		assert.are.equal("", vim.api.nvim_buf_get_lines(session.buf, 1, 2, false)[1])
	end)

	it("handles `dd` on a field's last line without touching the layout", function()
		local session = open()
		cursor(8, 0)
		vim.cmd("normal! dd")
		changed(session.buf)
		assert.are.equal("Line 1", regions.text(session.buf, region(session, "Description")))
		assert.are.equal("", vim.api.nvim_buf_get_lines(session.buf, 8, 9, false)[1])
		assert.are.equal("## Pr_link", vim.api.nvim_buf_get_lines(session.buf, 9, 10, false)[1])
	end)

	it("saves synchronously on :w", function()
		local session = open()
		cursor(0, 2)
		vim.api.nvim_buf_set_text(session.buf, 0, 2, 0, 11, { "Renamed" })
		changed(session.buf)
		vim.cmd("write")
		assert.are.equal(1, #calls)
		assert.is_true(calls[1].sync)
		assert.is_false(vim.bo[session.buf].modified)
		assert.matches("airtable://Renamed$", vim.api.nvim_buf_get_name(session.buf))
	end)

	it("saves pending edits when the buffer is wiped", function()
		local session = open()
		cursor(0, 2)
		vim.api.nvim_buf_set_text(session.buf, 0, 2, 0, 11, { "Bye" })
		changed(session.buf)
		vim.api.nvim_buf_delete(session.buf, { force = true })
		assert.are.equal(1, #calls)
		assert.are.same({ Title = "Bye" }, calls[1].fields)
	end)

	it("reuses the record's buffer when reopened, keeping unsaved edits", function()
		helpers.setup({ buffer = { autosave = { enabled = false } } })
		local session = open()
		cursor(7, 0)
		vim.api.nvim_buf_set_text(session.buf, 7, 0, 7, 6, { "Unsaved" })
		changed(session.buf)
		server.fields.Estimate = 8

		local again = open()
		assert.are.equal(session.buf, again.buf)
		assert.are.equal("Unsaved\nLine 2", regions.text(again.buf, region(again, "Description")))
		assert.are.equal("8", regions.text(again.buf, region(again, "Estimate")))
		assert.is_true(vim.bo[again.buf].modified)
	end)

	it("doesn't let undo go back past the initial render", function()
		local session = open()
		vim.cmd("silent! undo")
		assert.are.equal("# Fix login", vim.api.nvim_buf_get_lines(session.buf, 0, 1, false)[1])
	end)
end)
