-- highlight text yanks
vim.api.nvim_create_autocmd("TextYankPost", {
	desc = "Highlight when yanking text",
	group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
	callback = function()
		vim.highlight.on_yank()
	end,
})

vim.api.nvim_create_autocmd("FileType", {
	pattern = "TelescopePrompt",
	callback = function()
		vim.b.minicompletion_disable = true
	end,
})

-- clangd's include completions end with the closing quote, and mini.pairs already added one
vim.api.nvim_create_autocmd("CompleteDone", {
	pattern = { "*.c", "*.cpp", "*.h", "*.hpp" },
	callback = function()
		local word = vim.v.completed_item.word
		if not word or word == "" then
			return
		end
		local close = word:sub(-1)
		if close ~= '"' and close ~= ">" then
			return
		end
		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		if line:sub(col + 1, col + 1) == close then
			vim.api.nvim_set_current_line(line:sub(1, col) .. line:sub(col + 2))
		end
	end,
})
