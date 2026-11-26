local helpers = require("tests.helpers")
local api = require("airtable.api")
local render = require("airtable.render")
local regions = require("airtable.regions")
local autosave = require("airtable.autosave")

local function new_session()
	local record = helpers.record({ Title = "Fix login", Description = "Line 1", Estimate = 3 })
	local layout = render.layout(record, { editable = true, field_types = helpers.FIELD_TYPES })
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "acwrite" -- like the real record buffer; nofile can't be 'modified'
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
	local session = {
		buf = buf,
		record_id = record.id,
		record = record,
		regions = regions.attach(buf, layout.regions),
		baseline = {},
		saving = false,
		pending = false,
		has_saved = false,
		closed = false,
	}
	for _, spec in ipairs(layout.regions) do
		session.baseline[spec.field] = spec.baseline
	end
	return session
end

local function region(session, field)
	for _, r in ipairs(session.regions) do
		if r.field == field then
			return r
		end
	end
end

-- Replaces a region's whole text.
local function type_into(session, field, text)
	local sr, sc, er, ec = regions.range(session.buf, region(session, field))
	vim.api.nvim_buf_set_text(session.buf, sr, sc, er, ec, vim.split(text, "\n", { plain = true }))
	autosave.changed(session)
end

describe("autosave", function()
	local session, calls, restore_api, notified, restore_notify

	before_each(function()
		helpers.setup()
		notified, restore_notify = helpers.capture_notifications()
		calls = {}
		restore_api = helpers.stub(api, {
			update_record = function(record_id, fields, callback)
				local call = { record_id = record_id, fields = fields, callback = callback }
				table.insert(calls, call)
				if not callback then
					return { id = record_id, fields = fields }, nil
				end
			end,
		})
		session = new_session()
	end)

	after_each(function()
		autosave.close(session)
		vim.api.nvim_buf_delete(session.buf, { force = true })
		restore_api()
		restore_notify()
	end)

	local function errors()
		return vim.tbl_filter(function(n)
			return n.level == vim.log.levels.ERROR
		end, notified)
	end

	local function respond(call, err)
		if err then
			call.callback(nil, err)
		else
			call.callback({ id = call.record_id, fields = call.fields }, nil)
		end
	end

	it("does nothing when nothing changed", function()
		autosave.flush(session)
		assert.are.equal(0, #calls)
		assert.is_false(autosave.is_dirty(session))
	end)

	it("debounces rapid edits into a single PATCH of every dirty field", function()
		type_into(session, "Title", "F")
		type_into(session, "Title", "Fi")
		type_into(session, "Description", "Changed")
		assert.are.equal(0, #calls)
		assert.are.equal("dirty", session.status)
		assert.is_true(vim.bo[session.buf].modified)

		assert.is_true(helpers.wait_for(function()
			return #calls == 1
		end))
		vim.wait(60)
		assert.are.equal(1, #calls)
		assert.are.same({ Title = "Fi", Description = "Changed" }, calls[1].fields)
		assert.are.equal("saving", session.status)

		respond(calls[1])
		assert.are.equal("saved", session.status)
		assert.is_false(autosave.is_dirty(session))
		assert.is_false(vim.bo[session.buf].modified)
		assert.are.same({
			message = "Description, Title saved",
			level = vim.log.levels.INFO,
			title = "Airtable · Saved",
		}, notified[#notified])
	end)

	it("never overlaps saves: edits during a save are sent right after it", function()
		type_into(session, "Title", "One")
		autosave.flush(session)
		assert.are.equal(1, #calls)

		type_into(session, "Title", "Two")
		autosave.flush(session)
		assert.are.equal(1, #calls) -- queued, not sent

		respond(calls[1])
		assert.are.equal(2, #calls)
		assert.are.same({ Title = "Two" }, calls[2].fields)
		respond(calls[2])
		assert.are.equal("saved", session.status)
	end)

	it("doesn't resend a field whose save already succeeded", function()
		type_into(session, "Title", "One")
		autosave.flush(session)
		type_into(session, "Description", "Desc")
		autosave.flush(session)
		respond(calls[1])
		assert.are.same({ Description = "Desc" }, calls[2].fields)
	end)

	it("keeps the edit dirty on failure, toasts once, and recovers on the next success", function()
		type_into(session, "Title", "One")
		autosave.flush(session)
		respond(calls[1], { category = "API Error (422)", message = "bad" })
		assert.are.equal("error", session.status)
		assert.is_true(autosave.is_dirty(session))
		assert.are.equal(1, #errors())

		type_into(session, "Title", "One!")
		autosave.flush(session)
		respond(calls[2], { category = "API Error (422)", message = "bad" })
		assert.are.equal(1, #errors()) -- still failing: no new toast

		autosave.flush(session)
		respond(calls[3])
		assert.are.equal("saved", session.status)
		assert.is_nil(session.last_error)
	end)

	it("sends numbers as numbers, empty as null, and refuses non-numbers", function()
		type_into(session, "Estimate", " 4.5 ")
		autosave.flush(session)
		assert.are.equal(4.5, calls[1].fields.Estimate)
		respond(calls[1])

		type_into(session, "Estimate", "")
		autosave.flush(session)
		assert.are.equal(vim.NIL, calls[2].fields.Estimate)
		respond(calls[2])

		type_into(session, "Estimate", "lots")
		autosave.flush(session)
		assert.are.equal(2, #calls)
		assert.are.equal("error", session.status)
		assert.matches("not a number", errors()[1].message)
	end)

	it("sends a single-line field's line breaks as spaces", function()
		local r = region(session, "Title")
		local sr, sc, er, ec = regions.range(session.buf, r)
		vim.api.nvim_buf_set_text(session.buf, sr, sc, er, ec, { "a", "b" })
		autosave.flush(session)
		assert.are.same({ Title = "a b" }, calls[1].fields)
	end)

	it("saves synchronously on demand", function()
		type_into(session, "Description", "Now")
		local record = autosave.flush_sync(session)
		assert.are.equal(1, #calls)
		assert.is_nil(calls[1].callback)
		assert.are.equal("Now", record.fields.Description)
		assert.is_false(autosave.is_dirty(session))
	end)

	it("only saves on :w-style flushes when autosave is disabled", function()
		helpers.setup({ buffer = { autosave = { enabled = false } } })
		type_into(session, "Title", "Manual")
		vim.wait(80)
		assert.are.equal(0, #calls)
		autosave.flush_sync(session)
		assert.are.equal(1, #calls)
	end)
end)
