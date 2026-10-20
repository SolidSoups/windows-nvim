vim.opt.nu = true
vim.opt.relativenumber = true
vim.opt.cursorline = true

vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.autoindent = true
vim.opt.smartindent = true

vim.o.showmode = false

function _G.TabLine()
    local s = ""
    for i = 1, vim.fn.tabpagenr("$") do
        local buf = vim.fn.tabpagebuflist(i)[vim.fn.tabpagewinnr(i)]
        local name = vim.fn.fnamemodify(vim.fn.bufname(buf), ":t")
        if name == "" then
            name = "[No Name]"
        end
        local hl = i == vim.fn.tabpagenr() and "%#TabLineSel#" or "%#TabLine#"
        -- %{i}T makes the label clickable with the mouse
        s = s .. hl .. "%" .. i .. "T " .. name .. " "
    end
    return s .. "%#TabLineFill#%T"
end

vim.o.tabline = "%!v:lua.TabLine()"

vim.opt.wrap = false

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undodir = vim.fn.stdpath("data") .. "/undodir"
vim.opt.undofile = true

vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.termguicolors = true

vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes" -- display lsp and git status in column
vim.opt.colorcolumn = "120"

vim.opt.updatetime = 50

vim.opt.foldlevel = 99
