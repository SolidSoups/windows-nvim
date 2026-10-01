return {
	"nvim-mini/mini.nvim",
	version = false,
	config = function()
		require("mini.completion").setup({
			delay = { completion = 200, info = 400, signature = 100 },
			lsp_completion = {
				source_func = "omnifunc",
				auto_setup = true,
			},
			window = {
				info = { border = "single" },
				signature = { border = "single" },
			},
		})
		require("mini.pairs").setup()

        -- NO ' Pairings in rust
		vim.api.nvim_create_autocmd("FileType", {
            pattern = "rust",
			callback = function(ev)
                vim.keymap.set("i", "'", "'", { buffer = ev.buf })
			end,
		})
	end,
}
