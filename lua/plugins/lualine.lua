local lsp_progress = {}

vim.api.nvim_create_autocmd('LspProgress', {
    callback = function(args)
        local value = args.data.params.value
        if value.kind == 'end' then
            lsp_progress[args.data.client_id] = nil
        else
            lsp_progress[args.data.client_id] = value.percentage or 0
        end
        require('lualine').refresh()
    end
})

local function lsp()
    local names = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
        local pct = lsp_progress[client.id]
        table.insert(names, pct and (client.name .. ' ' .. pct .. '%%') or client.name)
    end
    return table.concat(names, ' ')
end


return {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = function()
        require 'lualine'.setup {
            options = {
                icons_enabled = true,
                theme = 'auto',
                component_separators = { left = ' ', right = ' ' },
                section_separators = { left = '', right = '' },
                disabled_filetypes = {
                    statusline = {},
                    winbar = {},
                },
                ignore_focus = {},
                always_divide_middle = true,
                globalstatus = true,
                refresh = {
                    statusline = 1000,
                    tabline = 1000,
                    winbar = 1000,
                    refresh_time = 16,
                    events = {
                        'WinEnter',
                        'BufEnter',
                        'BufWritePost',
                        'SessionLoadPost',
                        'FileChangedShellPost',
                        'VimResized',
                        'Filetype',
                        'CursorMoved',
                        'CursorMovedI',
                        'ModeChanged',
                    },
                },
            },
            sections = {
                lualine_a = { 'mode' },
                lualine_b = { 'branch', 'diff', 'diagnostics' },
                lualine_c = { 'filename' },
                lualine_x = { { lsp, icon = '' }, 'encoding', 'filetype' },
            },
            inactive_sections = {
                lualine_a = {},
                lualine_b = {},
                lualine_c = { 'filename' },
                lualine_x = { 'location' },
                lualine_y = {},
                lualine_z = {},
            },
            tabline = {},
            -- winbar = {
            --   lualine_c = {'filename'}
            -- },
            extensions = {}
        }
    end,
}
