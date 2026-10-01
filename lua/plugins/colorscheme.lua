return {
	{
		"vague-theme/vague.nvim",
		lazy = false,
		priority = 1000,
	},
	{
		"sainnhe/sonokai",
		priority = 1000,
		config = function()
			vim.g.sonokair_enable_italic = true
		end,
	},
	{
		"xiantang/darcula-dark.nvim",
		dependencies = { "nvim-treesitter/nvim-treesitter" },
	},
	{
		"EdenEast/nightfox.nvim",
		lazy = false,
		priority = 1000,
	},
	{
		"savq/melange-nvim",
	},
}
