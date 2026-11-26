local helpers = require("tests.helpers")
local render = require("airtable.render")

local record = helpers.record({
	Title = "Fix login",
	Status = "Todo",
	Description = "Line 1\nLine 2",
	Estimate = 3,
})

local function region_for(layout, field)
	for _, region in ipairs(layout.regions) do
		if region.field == field then
			return region
		end
	end
end

describe("render.layout", function()
	before_each(function()
		helpers.setup()
	end)

	it("renders read-only (preview) without regions, values as text", function()
		local layout = render.layout(record)
		assert.are.same({}, layout.regions)
		assert.are.same({
			"# Fix login",
			"",
			"", -- status pill (virtual text)
			"",
			"",
			"## Description",
			"",
			"Line 1",
			"Line 2",
			"",
			"## Pr_link",
			"",
			"_Empty._",
			"",
			"## Estimate",
			"",
			"3",
			"",
			"## Notes",
			"",
			"_Empty._",
			"",
		}, layout.lines)
	end)

	it("skips missing fields and excluded keys in preview mode", function()
		local layout = render.layout(record, { skip_missing = true, exclude = { status = true } })
		assert.are.same({
			"# Fix login",
			"",
			"## Description",
			"",
			"Line 1",
			"Line 2",
			"",
			"## Estimate",
			"",
			"3",
			"",
		}, layout.lines)
	end)

	describe("editable", function()
		local layout
		before_each(function()
			layout = render.layout(record, { editable = true, field_types = helpers.FIELD_TYPES })
		end)

		it("makes the title an inline single-line region after '# '", function()
			local title = region_for(layout, "Title")
			assert.are.same({ "inline", 0, 2, 0, 11, "Fix login", true }, {
				title.kind,
				title.start_row,
				title.start_col,
				title.end_row,
				title.end_col,
				title.baseline,
				title.single_line,
			})
		end)

		it("makes plain sections block regions covering exactly the body lines", function()
			local description = region_for(layout, "Description")
			assert.are.equal("block", description.kind)
			assert.are.same({ 7, 0, 8, 6 }, {
				description.start_row,
				description.start_col,
				description.end_row,
				description.end_col,
			})
			assert.are.equal("Line 1\nLine 2", description.baseline)
			assert.is_false(description.single_line)
			assert.is_not_nil(description.border)
		end)

		it("renders an empty editable field as an empty line, not a placeholder text", function()
			local pr = region_for(layout, "PR link")
			assert.are.equal("", layout.lines[pr.start_row + 1])
			assert.are.same({ 12, 0, 12, 0 }, { pr.start_row, pr.start_col, pr.end_row, pr.end_col })
			assert.is_true(pr.single_line)
		end)

		it("keeps non-text fields and select fields read-only", function()
			assert.is_nil(region_for(layout, "Status"))
			assert.is_nil(region_for(layout, "Notes"))
			assert.are.equal("_Empty._", layout.lines[21])
		end)

		it("carries the field type for coercion", function()
			assert.are.equal("number", region_for(layout, "Estimate").field_type)
		end)

		it("does not make a text-configured field editable if the schema says it isn't text", function()
			local types = vim.tbl_extend("force", helpers.FIELD_TYPES, { Description = "multipleAttachments" })
			local l = render.layout(record, { editable = true, field_types = types })
			assert.is_nil(region_for(l, "Description"))
		end)

		it("treats unknown field types (no schema) as multi-line text", function()
			local l = render.layout(record, { editable = true })
			local pr = region_for(l, "PR link")
			assert.is_not_nil(pr)
			assert.is_false(pr.single_line)
		end)

		it("overrides record values with `values`, keeping the record's baseline", function()
			local l = render.layout(record, {
				editable = true,
				field_types = helpers.FIELD_TYPES,
				values = { Description = "edited\nthree\nlines" },
			})
			local description = region_for(l, "Description")
			assert.are.same({ "edited", "three", "lines" }, { l.lines[8], l.lines[9], l.lines[10] })
			assert.are.same({ 7, 9 }, { description.start_row, description.end_row })
			assert.are.equal("Line 1\nLine 2", description.baseline)
		end)

		it("joins line breaks in single-line fields", function()
			local l = render.layout(record, {
				editable = true,
				field_types = helpers.FIELD_TYPES,
				values = { Title = "a\nb" },
			})
			assert.are.equal("# a b", l.lines[1])
		end)

		it("records the first row of every section", function()
			local rows = {}
			for _, section in ipairs(layout.sections) do
				rows[section.key] = section.row
			end
			assert.are.same({ title = 0, status = 2, description = 5, pr_link = 10, estimate = 14, notes = 18 }, rows)
		end)
	end)

	it("uses a title key in any case as the H1, not as a section", function()
		helpers.setup({
			buffer = {
				fields = { { key = "Title", field = "Titre" }, { key = "Created By", field = "Created By" } },
				editable = { { field = "Titre", type = "text" } },
			},
		})
		local rec = helpers.record({ Titre = "Simulateur Retraite", ["Created By"] = "Maxime" })
		local l = render.layout(rec, { editable = true, field_types = { Titre = "singleLineText" } })
		assert.are.equal("# Simulateur Retraite", l.lines[1])
		assert.are.equal("Titre", l.regions[1].field)
		assert.are.equal(1, #l.regions)
		assert.is_nil(vim.iter(l.lines):find(function(line)
			return line:find("Simulateur", 1, true) ~= nil and line:sub(1, 2) ~= "# "
		end))
		assert.are.equal("# Simulateur Retraite", render.layout(rec).lines[1])
	end)

	it("makes heading-style fields inline regions after 'Key: '", function()
		helpers.setup({
			buffer = {
				fields = { { key = "title", field = "Title" }, { key = "ticket_name", field = "Name" } },
				editable = { { field = "Name", type = "text" } },
			},
		})
		local l = render.layout(helpers.record({ Title = "T", Name = "Alpha" }), {
			editable = true,
			field_types = { Name = "singleLineText" },
		})
		assert.are.equal("Ticket_name: Alpha", l.lines[4])
		local name = l.regions[1]
		assert.are.same(
			{ "inline", 3, 13, 3, 18 },
			{ name.kind, name.start_row, name.start_col, name.end_row, name.end_col }
		)
	end)

	it("gives every editable section the editable bar, heading-style ones included", function()
		helpers.setup({
			buffer = {
				fields = {
					{ key = "title", field = "Title" },
					{ key = "ticket_name", field = "Name" },
					{ key = "ticket_id", field = "Ref" },
					{ key = "app_name", field = "App" },
				},
				editable = { { field = "Name", type = "text" }, { field = "Ref", type = "select" } },
			},
		})
		local rec = helpers.record({ Title = "T", Name = "Alpha", Ref = "R-1", App = "Web" })
		local l = render.layout(rec, { editable = true, field_types = { Name = "singleLineText" } })
		local editable_hl = render.border_hl("Name")
		assert.are_not.equal("Comment", editable_hl)

		-- text field: the region carries the bar (drawn per row by regions.decorate)
		assert.are.same({ render.left_border(), editable_hl }, l.regions[1].border)

		local function bar_on(row)
			for _, mark in ipairs(l.extmarks) do
				if mark.line == row and mark.opts.virt_text_pos == "inline" then
					return mark.opts.virt_text[1][2]
				end
			end
		end
		assert.are.equal("Ticket_id: R-1", l.lines[7])
		assert.are.equal(editable_hl, bar_on(6)) -- select field
		assert.are.equal("App_name: Web", l.lines[10])
		assert.is_nil(bar_on(9)) -- read-only: unchanged, no bar
	end)
end)
