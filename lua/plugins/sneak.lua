return {
	{ "tpope/vim-repeat" },
	{
		"https://codeberg.org/andyg/leap.nvim",
		config = function()
			vim.keymap.set({ "n", "x", "o" }, "s", "<Plug>(leap)")
			vim.keymap.set("n", "S", "<Plug>(leap-from-window)")

			vim.keymap.set({ "n", "o" }, "gs", function()
				require("leap.remote").action({
					-- Automatically enter Visual mode when coming from Normal.
					input = vim.fn.mode(true):match("o") and "" or "v",
				})
			end)

			-- Define equivalence classes for brackets and quotes, in addition to
			-- the default whitespace group:
			require("leap").opts.equivalence_classes = { " \t\r\n", "([{", ")]}", "'\"`" }

			-- Automatic paste after remote yank operations:
			vim.api.nvim_create_autocmd("User", {
				pattern = "RemoteOperationDone",
				group = vim.api.nvim_create_augroup("LeapRemote", {}),
				callback = function(event)
					if vim.v.operator == "y" and event.data.register == '"' then
						vim.cmd("normal! p")
					end
				end,
			})

			vim.keymap.set("n", "<leader>s", function()
				require("leap").leap({
					target_windows = vim.tbl_filter(function(win)
						return vim.api.nvim_win_get_config(win).focusable
					end, vim.api.nvim_tabpage_list_wins(0)),
				})
			end)
		end,
	},
}
