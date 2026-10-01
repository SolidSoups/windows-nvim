return {
	"nvim-treesitter/nvim-treesitter",
	lazy = false,
	build = ":TSUpdate",
	config = function()
		require("nvim-treesitter").setup({
			install_dir = vim.fn.stdpath("data") .. "/site",
		})

		local parsers = {
			"javascript",
			"typescript",
			"cpp",
			"c",
			"python",
			"lua",
			"css",
			"tsx",
			"html", -- svelte's highlight queries inherit from html
			"svelte",
			"gdscript",
			"gdshader",
			"rust",
			"wgsl",
		}
		require("nvim-treesitter").install(parsers)

		vim.api.nvim_create_autocmd("FileType", {
			pattern = {
				"javascript",
				"javascriptreact",
				"typescript",
				"typescriptreact",
				"cpp",
				"c",
				"python",
				"css",
				"svelte",
				"rust",
				"wgsl",
			},
			callback = function(args)
				vim.treesitter.start()
				vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
				vim.wo[0][0].foldmethod = "expr"
				-- experimental indentation; rust keeps the built-in indenter
				if args.match == "svelte" then
					-- treesitter alone gives column 0 in half-typed markup, see config/svelte-indent.lua
					vim.bo.indentexpr = "v:lua.require'config.svelte-indent'.indentexpr()"
					-- re-indent when > is typed, so closing tags snap into place
					vim.cmd("setlocal indentkeys+=<>>")
				elseif args.match ~= "rust" then
					vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
				end
				vim.wo.foldlevel = 99
			end,
		})
	end,
}
