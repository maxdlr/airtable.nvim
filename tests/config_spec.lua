local helpers = require("tests.helpers")
local config = require("airtable.config")

describe("config", function()
	local notified, restore
	before_each(function()
		notified, restore = helpers.capture_notifications()
	end)
	after_each(function()
		restore()
	end)

	it("defaults autosave to on with a 1000ms debounce", function()
		config.setup({ base_id = "app", table_name = "T" })
		assert.are.same({ enabled = true, debounce_ms = 1000 }, config.options.buffer.autosave)
		assert.are.equal(0, #notified)
	end)

	it("rejects invalid autosave values and falls back to defaults", function()
		config.setup({
			base_id = "app",
			table_name = "T",
			buffer = { autosave = { enabled = "yes", debounce_ms = -1 } },
		})
		assert.are.same({ enabled = true, debounce_ms = 1000 }, config.options.buffer.autosave)
		assert.are.equal(2, #notified)
	end)

	it("distinguishes inline (text) from picker (select) editable fields", function()
		helpers.setup()
		assert.is_true(config.is_inline_editable("Description"))
		assert.is_false(config.is_inline_editable("Status"))
		assert.is_false(config.is_inline_editable("Notes"))
		assert.are.equal("select", config.editable_entry("Status").type)
	end)
end)
