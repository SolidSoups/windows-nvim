return {
    "neovim/nvim-lspconfig",
    config = function()
        vim.lsp.enable({
            "clangd",
            "lua_ls",
            "tailwindcss",
            "cssls",
            "svelte",
            "ts_ls",
            "gdscript",
            "rust_analyzer",
            "wgsl_analyzer",
        })

        -- GDScript config (requires the Godot editor running with LSP enabled on this port)
        vim.lsp.config("gdscript", {
            cmd = vim.lsp.rpc.connect("127.0.0.1", 6005),
            filetypes = { "gd", "gdscript", "gdscript3" },
            root_markers = { "project.godot", ".git" },
        })

        -- Lua LS config
        vim.lsp.config("lua_ls", {
            settings = {
                Lua = {
                    diagnostics = {
                        globals = { "vim" },
                    },
                    workspace = {
                        library = {
                            [vim.env.VIMRUNTIME] = true,
                        },
                    },
                },
            },
        })

        -- Rust config
        vim.lsp.config("rust_analyzer", {
            settings = {
                ["rust-analyzer"] = {
                    diagnostics = {
                        disabled = { "inactive-code", "unlinked-file" },
                    },
                },
            },
        })

        -- Clangd config
        vim.lsp.config("clangd", {
            cmd = { 
                "clangd",
                "--log=error",
                "--completion-style=bundled",
                "--limit-results=30",
                "--offset-encoding=utf-16" ,
                "--background-index",
                "--header-insertion=never",
                "-j=8"
            },
            root_markers = { "compile_commands.json", ".clangd", ".git" },
            capabilities = {
                textDocument = { inactiveRegionsCapabilities = { inactiveRegions = true } },
            },
            handles = {
                ["textDocument/inactiveRegions"] = function(...)
                    require("config.cpp_regions").on_inactive_regions(...)
                end
            }
        })

        -- CSS config (Tailwind at-rules like @theme and @apply aren't standard CSS)
        vim.lsp.config("cssls", {
            settings = {
                css = {
                    lint = {
                        unknownAtRules = "ignore",
                    },
                },
            },
        })

        vim.api.nvim_create_user_command("LspRestart", function()
            vim.lsp.stop_client(vim.lsp.get_clients({ bufnr = 0 }))
            vim.cmd.edit()
        end, {})

        vim.api.nvim_create_user_command("LspInfo", function()
            vim.cmd("checkhealth vim.lsp")
        end, {})
    end,
}
