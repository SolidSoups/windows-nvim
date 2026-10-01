vim.g.mapleader = " "

vim.keymap.set("n", "-", "<CMD>Oil<CR>", { desc = "Open parent directory" })

-- move lines up and down more easily
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selected lines down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selected lines up" })

-- Esc for ctrl+c
vim.keymap.set("i", "<C-c>", "<Esc>")

-- rebind quickfix (to free up q)
vim.keymap.set("n", "<leader>qn", ":cnext<CR>", { silent = true, desc = "Quick fix next item" })
vim.keymap.set("n", "<leader>qp", ":cprevious<CR>", { silent = true, desc = "Quick fix previous item" })
vim.keymap.set("n", "<leader>qd", ":cdo s/", { silent = false, desc = "Quick fix begin replace" })
vim.keymap.set("n", "<leader>qc", ":cclose<CR>", { silent = true, desc = "Quick fix close" })
vim.keymap.set("n", "<leader>qx", ":cdelete<CR>", { silent = true, desc = "Quick fix remove" })
vim.keymap.set("n", "<leader>qa", ":QFAdd<CR>", { silent = true, desc = "Quick fix add" })

-- window management
vim.keymap.set("n", "<leader>sv", ":vsplit<CR><C-w>l", { silent = true, desc = "Split vertically" })
vim.keymap.set("n", "<leader>sh", ":split<CR><C-w>j", { silent = true, desc = "Split horizontally" })

-- add lsp keymaps on lsp attach
vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(event)
		local opts = { buffer = event.buf }
		vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
		vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
		vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
		vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
		vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
		vim.keymap.set("n", "<leader>lr", ":LspRestart<CR>", { silent = true, desc = "Restart LSP" })
	end,
})

-- open config
vim.keymap.set("n", "<leader>nc", function()
    vim.cmd.edit(vim.fn.stdpath("config"))
end, { desc = "Open Neovim config directory" })
