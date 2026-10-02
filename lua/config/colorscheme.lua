require("vague").setup({
	transparent = true,
})

vim.g.sonokai_transparent_background = 1

vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
        for _, group in ipairs({
            "Normal",
            "NormalNC",
            "NormalFloat",
            "FloatBorder",
            "SignColumn",
            "LineNr",
            "FoldColumn",
            "EndOfBuffer",
        }) do
            local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
            hl.bg = "NONE"
            hl.ctermbg = "NONE"
            vim.api.nvim_set_hl(0, group, hl)
        end

        -- Make split separators more visible with transperancy
        vim.api.nvim_set_hl(0, "WinSeparator", { fg = "#89b4fa", bg = "NONE" })
        -- Also highlight inactive statuslines with the same color
        vim.api.nvim_set_hl(0, "StatusLineNC", { fg = "#89b4fa", bg = "NONE" })
    end
})

vim.cmd("colorscheme melange")

-- Make split seperators more visible with transparency
vim.api.nvim_set_hl(0, "WinSeparator", { fg = "#89b4fa", bg = "NONE" })
-- Also highlight inactive statuslines with the same color
vim.api.nvim_set_hl(0, "StatusLineNC", { fg = "#89b4fa", bg = "NONE" })

-- Give cpp regions a color
vim.api.nvim_set_hl(0, "@markup.heading.cpp", { fg = "#89b4fa", bold = true })

vim.o.winborder = "bold"
