local helpers = require("tests.helpers")
local render = require("airtable.render")
local regions = require("airtable.regions")

local function setup_buffer()
	local layout = render.layout(
		helpers.record({ Title = "Fix login", Status = "Todo", Description = "Line 1\nLine 2", Estimate = 3 }),
		{ editable = true, field_types = helpers.FIELD_TYPES }
	)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
	local attached = regions.attach(buf, layout.regions)
	local by_field = {}
	for _, region in ipairs(attached) do
		by_field[region.field] = region
	end
	return buf, attached, by_field
end

describe("regions", function()
	local buf, all, r, static
	before_each(function()
		helpers.setup()
		buf, all, r = setup_buffer()
		static = regions.static_text(buf, all)
	end)
	after_each(function()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("reads each region's text", function()
		assert.are.same(
			{ Title = "Fix login", Description = "Line 1\nLine 2", ["PR link"] = "", Estimate = "3" },
			regions.values(buf, all)
		)
	end)

	it("grows when text is typed at the end of a region", function()
		vim.api.nvim_buf_set_text(buf, 0, 11, 0, 11, { "!!" })
		assert.are.equal("Fix login!!", regions.text(buf, r.Title))
		assert.are.equal(static, regions.static_text(buf, all))
	end)

	it("grows when text is typed at the start of a region", function()
		vim.api.nvim_buf_set_text(buf, 0, 2, 0, 2, { "WIP " })
		assert.are.equal("WIP Fix login", regions.text(buf, r.Title))
		assert.are.equal(static, regions.static_text(buf, all))
	end)

	it("includes a line opened below the last line (`o`)", function()
		vim.api.nvim_buf_set_text(buf, 8, 6, 8, 6, { "", "Line 3" })
		assert.are.equal("Line 1\nLine 2\nLine 3", regions.text(buf, r.Description))
		assert.are.equal(static, regions.static_text(buf, all))
	end)

	it("includes a line opened above the first line (`O`)", function()
		vim.api.nvim_buf_set_text(buf, 7, 0, 7, 0, { "Line 0", "" })
		assert.are.equal("Line 0\nLine 1\nLine 2", regions.text(buf, r.Description))
		assert.are.equal(static, regions.static_text(buf, all))
	end)

	it("lets an empty region be typed into", function()
		vim.api.nvim_buf_set_text(buf, 12, 0, 12, 0, { "https://x.y/1" })
		assert.are.equal("https://x.y/1", regions.text(buf, r["PR link"]))
		assert.are.equal(static, regions.static_text(buf, all))
	end)

	it("keeps the following static text intact when the last line is deleted (`dd`)", function()
		vim.api.nvim_buf_set_lines(buf, 8, 9, false, {})
		regions.normalize(buf, all)
		assert.are.equal("Line 1", regions.text(buf, r.Description))
		assert.are.equal(static, regions.static_text(buf, all))
	end)

	it("detects edits to static text", function()
		vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "## Hacked" })
		assert.are_not.equal(static, regions.static_text(buf, all))
	end)

	it("detects a deleted line break between a region and static text", function()
		-- <BS> at the start of the Description body joins it with the blank line above.
		vim.api.nvim_buf_set_text(buf, 6, 0, 7, 0, { "" })
		assert.are_not.equal(static, regions.static_text(buf, all))
	end)

	it("finds the region at a position, end inclusive", function()
		assert.are.equal(r.Title, regions.at(buf, all, 0, 2))
		assert.are.equal(r.Title, regions.at(buf, all, 0, 11))
		assert.is_nil(regions.at(buf, all, 0, 1))
		assert.are.equal(r.Description, regions.at(buf, all, 8, 3))
		assert.is_nil(regions.at(buf, all, 5, 0))
		assert.are.equal(r["PR link"], regions.at(buf, all, 12, 0))
	end)

	it("knows the region edges", function()
		assert.is_true(regions.is_at_start(buf, r.Description, 7, 0))
		assert.is_false(regions.is_at_start(buf, r.Description, 8, 0))
		assert.is_true(regions.is_at_end(buf, r.Description, 8, 6))
	end)

	it("draws a placeholder only for empty regions", function()
		regions.decorate(buf, all)
		local marks = vim.api.nvim_buf_get_extmarks(buf, regions.DECOR_NS, 0, -1, { details = true })
		local placeholders = vim.tbl_filter(function(m)
			return m[4].virt_text_pos == "eol"
		end, marks)
		assert.are.equal(1, #placeholders)
		assert.are.equal(12, placeholders[1][2])
		assert.are.equal("_Empty._", placeholders[1][4].virt_text[1][1])
	end)

	it("borders every row of a block region, including new ones", function()
		vim.api.nvim_buf_set_text(buf, 8, 6, 8, 6, { "", "Line 3" })
		regions.decorate(buf, all)
		local rows = {}
		for _, m in
			ipairs(vim.api.nvim_buf_get_extmarks(buf, regions.DECOR_NS, { 7, 0 }, { 9, -1 }, { details = true }))
		do
			if m[4].virt_text_pos == "inline" then
				rows[m[2]] = true
			end
		end
		assert.are.same({ [7] = true, [8] = true, [9] = true }, rows)
	end)
end)
