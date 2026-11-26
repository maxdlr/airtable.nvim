-- Headless test environment: this plugin + plenary, nothing else from the user config.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function find_plenary()
	local data = vim.fn.stdpath("data")
	local candidates = {
		vim.env.PLENARY_DIR,
		data .. "/site/pack/core/opt/plenary.nvim",
		data .. "/lazy/plenary.nvim",
		root .. "/.tests/plenary.nvim",
	}
	for _, path in ipairs(candidates) do
		if path and path ~= "" and vim.uv.fs_stat(path) then
			return path
		end
	end
	local dest = root .. "/.tests/plenary.nvim"
	vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", dest })
	return dest
end

vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(find_plenary())
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
vim.o.shadafile = "NONE"
