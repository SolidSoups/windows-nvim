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
                local cpp = args.match == "c" or args.match == "cpp"
                vim.wo[0][0].foldexpr = cpp and "v:lua.require'config.cpp_regions'.foldexpr()" 
                    or "v:lua.vim.treesitter.foldexpr()"
                if cpp then
                    -- % jumps between #pragma region and endregion, next to the built-in #if/#else/#endif pairs
                    local words = vim.b.match_words or ""
                    vim.b.match_words = (words ~= "" and words .. "," or "")
                        .. [[^\s*#\s*pragma\s\+region\>:^\s*#\s*pragma\s\+endregion\>]]
                end
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
