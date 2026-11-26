-- Drives the record buffer with real keystrokes (feedkeys), to cover the insert-mode
-- gating and guard mappings the API-level tests can't reach.
local helpers = require("tests.helpers")
local api = require("airtable.api")
local view = require("airtable.view")
local regions = require("airtable.regions")

-- feedkeys "x" runs the keys without returning to the main loop, so TextChanged never
-- fires on its own: fire it like the loop would once typing stops.
local function keys(str)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(str, true, false, true), "xt", false)
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
end

describe("record buffer keystrokes", function()
	local session, calls, restore_api, notified, restore_notify, server_fields

	local function warnings()
		return vim.tbl_filter(function(n)
			return n.level >= vim.log.levels.WARN
		end, notified)
	end
	local function lines()
		return vim.api.nvim_buf_get_lines(session.buf, 0, -1, false)
	end
	local function text(field)
		for _, r in ipairs(session.regions) do
			if r.field == field then
				return regions.text(session.buf, r)
			end
		end
	end
	local function cursor(row, col)
		vim.api.nvim_win_set_cursor(0, { row + 1, col })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
	end

	before_each(function()
		helpers.setup()
		notified, restore_notify = helpers.capture_notifications()
		calls = {}
		server_fields = { Title = "Fix login", Description = "Line 1\nLine 2", Estimate = 3 }
		local server = helpers.record(server_fields)
		restore_api = helpers.stub(api, {
			get_field_types = function(cb)
				cb(helpers.FIELD_TYPES, nil)
			end,
			get_recordById = function(_, cb)
				cb(vim.deepcopy(server), nil)
			end,
			update_record = function(_, fields, callback)
				table.insert(calls, fields)
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
		view.open("recTEST1")
		helpers.wait_for(function()
			return view.session(vim.api.nvim_get_current_buf()) ~= nil
		end)
		session = view.session(vim.api.nvim_get_current_buf())
	end)

	after_each(function()
		vim.cmd("stopinsert")
		if vim.api.nvim_buf_is_valid(session.buf) then
			vim.api.nvim_buf_delete(session.buf, { force = true })
		end
		restore_api()
		restore_notify()
	end)

	it("types into a field in insert mode and autosaves it", function()
		cursor(7, 0)
		keys("A more<Esc>")
		assert.are.equal("Line 1 more\nLine 2", text("Description"))
		assert.is_true(helpers.wait_for(function()
			return #calls == 1
		end))
		assert.are.same({ Description = "Line 1 more\nLine 2" }, calls[1])
	end)

	it("adds lines to a multi-line field with o and <CR>", function()
		cursor(8, 0)
		keys("oLine 3<CR>Line 4<Esc>")
		assert.are.equal("Line 1\nLine 2\nLine 3\nLine 4", text("Description"))
		assert.are.equal("", lines()[12])
		assert.are.equal("## Pr_link", lines()[13])
	end)

	it("refuses typing on read-only lines", function()
		cursor(5, 0) -- "## Description"
		pcall(keys, "ixyz<Esc>")
		assert.are.equal("## Description", lines()[6])
	end)

	it("blocks <BS> at a field's start instead of joining it with the line above", function()
		cursor(7, 0)
		keys("i<BS><BS><Esc>")
		assert.are.equal("", lines()[7])
		assert.are.equal("Line 1", lines()[8])
	end)

	it("keeps single-line fields single-line (o, <CR>)", function()
		cursor(0, 5)
		keys("o")
		keys("A<CR>!<Esc>")
		assert.are.equal("# Fix login!", lines()[1])
		assert.are.equal("", lines()[2])
	end)

	it("supports change operators inside a field", function()
		cursor(0, 2)
		keys("ciwRepair<Esc>")
		assert.are.equal("Repair login", text("Title"))
	end)

	it("undo of an edit is itself saved", function()
		cursor(0, 2)
		keys("ciwRepair<Esc>")
		vim.cmd("write")
		keys("u")
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = session.buf })
		assert.are.equal("Fix login", text("Title"))
		vim.cmd("write")
		assert.are.same({ Title = "Fix login" }, calls[#calls])
	end)

	describe("with a value ending in a line break", function()
		before_each(function()
			vim.api.nvim_buf_delete(session.buf, { force = true })
			server_fields.Description = "Line 1\n"
			view.open("recTEST1")
			helpers.wait_for(function()
				return view.session(vim.api.nvim_get_current_buf()) ~= nil
			end)
			session = view.session(vim.api.nvim_get_current_buf())
		end)

		it("edits it without a read-only violation and keeps the trailing break", function()
			cursor(7, 0)
			keys("A more<Esc>")
			vim.wait(30)
			assert.are.same({}, warnings())
			assert.are.equal("Line 1 more\n", text("Description"))
		end)

		it("still deletes its empty last line cleanly with dd", function()
			cursor(8, 0)
			keys("dd")
			vim.wait(30)
			assert.are.same({}, warnings())
			assert.are.equal("Line 1", text("Description"))
			assert.are.equal("## Pr_link", lines()[10])
		end)
	end)

	it("opens the URL under the cursor with go", function()
		local opened
		local restore = helpers.stub(vim.ui, {
			open = function(url)
				opened = url
			end,
		})
		cursor(12, 0)
		keys("ihttps://x.y/1<Esc>")
		cursor(12, 4)
		keys("go")
		restore()
		assert.are.equal("https://x.y/1", opened)
	end)

	it("keeps 'e' as the end-of-word motion outside select fields", function()
		cursor(7, 0)
		keys("e")
		assert.are.same({ 8, 3 }, vim.api.nvim_win_get_cursor(0))
	end)

	it("pastes lines below a field's last line into the field (yyp)", function()
		cursor(8, 0)
		keys("yyp")
		assert.are.equal("Line 1\nLine 2\nLine 2", text("Description"))
		assert.are.equal("## Pr_link", lines()[12])
	end)

	it("opens a line above a field's first line into the field (O)", function()
		cursor(7, 0)
		keys("OLine 0<Esc>")
		assert.are.equal("Line 0\nLine 1\nLine 2", text("Description"))
		assert.are.equal("", lines()[7])
	end)

	it("puts the cursor at a field's end and makes it editable from focus_field", function()
		view.focus_field(session, "Estimate")
		vim.wait(20)
		vim.cmd("stopinsert")
		assert.are.same({ 17, 1 }, vim.api.nvim_win_get_cursor(0))
		assert.is_true(vim.bo[session.buf].modifiable)
	end)
end)
