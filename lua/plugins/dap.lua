local python_dir = vim.fn.expand("~/.pyenv/pyenv-win/versions/3.13.13")

-- nvim-dap hands options.env to the process as its whole environment, so start from Neovim's own.
-- Windows names are case-insensitive, and PATH is usually spelled Path
local function lldb_env()
    local env = {}
    for name, value in pairs(vim.fn.environ()) do
        local upper = name:upper()
        if upper == "PATH" then
            value = python_dir .. ";" .. value
        end
        if upper ~= "LLDB_USE_LLDB_SERVER" then
            table.insert(env, name .. "=" .. value)
        end
    end
    table.insert(env, "LLDB_USE_LLDB_SERVER=0")
    return env
end

-- F5 doubles as "start debugging", the way it does in Visual Studio and Rider
local function continue_or_attach()
    if require("dap").session() then
        require("dap").continue()
    else
        vim.cmd("UnrealAttach")
    end
end

local function conditional_breakpoint()
    require("dap").set_breakpoint(vim.fn.input("Condition: "))
end

return {
    {
        "mfussenegger/nvim-dap",
        -- loads on the first require("dap"), from the Unreal commands or a debug key
        lazy = true,
        keys = {
            { "<F5>", continue_or_attach, desc = "Debug: continue, or attach to the Unreal editor" },
            { "<S-F5>", "<Cmd>UnrealDetach<CR>", desc = "Debug: detach, leaving the editor running" },
            { "<F9>", function() require("dap").toggle_breakpoint() end, desc = "Debug: toggle breakpoint" },
            { "<S-F9>", conditional_breakpoint, desc = "Debug: conditional breakpoint" },
            { "<F10>", function() require("dap").step_over() end, desc = "Debug: step over" },
            { "<F11>", function() require("dap").step_into() end, desc = "Debug: step into" },
            { "<S-F11>", function() require("dap").step_out() end, desc = "Debug: step out" },
            -- the same under <leader>d, for when the terminal swallows a function key
            { "<leader>dc", continue_or_attach, desc = "Debug: continue, or attach to the Unreal editor" },
            { "<leader>dd", "<Cmd>UnrealDetach<CR>", desc = "Debug: detach, leaving the editor running" },
            { "<leader>db", function() require("dap").toggle_breakpoint() end, desc = "Debug: toggle breakpoint" },
            { "<leader>dB", conditional_breakpoint, desc = "Debug: conditional breakpoint" },
            { "<leader>dn", function() require("dap").step_over() end, desc = "Debug: step over" },
            { "<leader>di", function() require("dap").step_into() end, desc = "Debug: step into" },
            { "<leader>do", function() require("dap").step_out() end, desc = "Debug: step out" },
            { "<leader>dh", function() require("dap.ui.widgets").hover() end, desc = "Debug: value under cursor" },
            { "<leader>dw", "<Cmd>DapViewWatch<CR>", desc = "Debug: watch expression under cursor" },
            { "<leader>dv", "<Cmd>DapViewToggle<CR>", desc = "Debug: toggle panels" },
        },
        config = function()
            local dap = require("dap")
            dap.adapters.lldb = {
                type = "executable",
                command = "C:/Program Files/LLVM/bin/lldb-dap.exe",
                name = "lldb",
                options = {
                    env = lldb_env(),
                    -- nvim-dap's timer runs until the attach answers, and LLDB reads every editor DLL's
                    -- symbol table first. That takes several seconds, past nvim-dap's 4 second default
                    initialize_timeout_sec = 30,
                },
            }

            -- nvim-dap stops the adapter after every session, and on Windows libuv does that with TerminateProcess
            -- and exit code 1, so each clean end warns "exited with 1". Hide that one warning, but only after a
            -- session ended normally, so a crash still shows
            local exit_expected = false
            dap.listeners.after.disconnect["unreal_quiet_exit"] = function()
                exit_expected = true
            end
            dap.listeners.before.event_terminated["unreal_quiet_exit"] = function()
                exit_expected = true
            end
            local notify = vim.notify
            vim.notify = function(msg, level, opts)
                if exit_expected and type(msg) == "string"
                    and msg:find("lldb-dap.exe` of adapter `lldb` exited with 1", 1, true) then
                    exit_expected = false
                    return
                end
                return notify(msg, level, opts)
            end

            -- linked to diagnostic groups, so they follow the colorscheme
            vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
            vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DiagnosticError" })
            vim.fn.sign_define("DapLogPoint", { text = "◆", texthl = "DiagnosticInfo" })
            vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "DiagnosticWarn" })
            vim.fn.sign_define("DapStopped", { text = "→", texthl = "DiagnosticWarn", linehl = "Visual" })

            -- loads the panels now, so they can open with the first session
            require("dap-view")
        end,
    },
    {
        "igorlfs/nvim-dap-view",
        version = "1.*",
        lazy = true,
        opts = {
            winbar = {
                -- no console or exceptions: an attached editor has no terminal, and Unreal doesn't use C++ exceptions
                sections = { "scopes", "watches", "threads", "breakpoints", "repl" },
                default_section = "scopes",
            },
            windows = { size = 0.3, position = "below" },
            -- open when a session starts, close when it ends
            auto_toggle = true,
        },
    },
}
