-- project and plugin descriptors are plain JSON
vim.filetype.add({
    extension = {
        uproject = "json",
        uplugin = "json",
    }
})

local function find_unreal_root()
    return vim.fs.root(0, function(name)
        return name:match("%.uproject$") ~= nil
    end)
end


local function find_uproject()
    local root = find_unreal_root()
    if not root then
        return nil
    end
    return vim.fn.glob(root .. "/*.uproject", false, true)[1]
end

local function read_json(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a"):gsub("^\239\187\191", "") -- strip a UTF-8 byte order mark
    file:close()
    local ok, data = pcall(vim.json.decode, content)
    return ok and data or nil
end

-- launcher installs are listed as UE_<version>, matching the .uproject's EngineAssociation
local function find_engine_root(uproject)
    local project = read_json(uproject)
    local association = project and project.EngineAssociation
    if not association then
        return nil
    end

    local launcher = read_json("C:/ProgramData/Epic/UnrealEngineLauncher/LauncherInstalled.dat")
    for _, install in ipairs(launcher and launcher.InstallationList or {}) do
        if install.AppName == "UE_" .. association then
            return install.InstallLocation
        end
    end
    return nil
end

local function find_editor_target(root)
    local target = vim.fn.glob(root .. "/Source/*Editor.Target.cs", false, true)[1]
    return target and (vim.fn.fnamemodify(target, ":t"):gsub("%.Target%.cs$", ""))
end

-- VS Code project generation keeps its compile commands and flag files under .vscode,
-- so unlike GenerateClangDatabase it never touches the build's own flag files and doesn't force a full rebuild
local last_db_signature

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function regenerate_clang_db()
    local uproject = find_uproject()
    if not uproject then
        vim.notify("No .uproject above this file", vim.log.levels.ERROR)
        return
    end
    local root = vim.fs.dirname(uproject)
    local engine = find_engine_root(uproject)
    if not engine then
        vim.notify("Can't find the engine for " .. uproject, vim.log.levels.ERROR)
        return
    end
    local name = vim.fn.fnamemodify(uproject, ":t:r")

    local cmd = {
        engine .. "/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe",
        "-projectfiles",
        "-vscode",
        "-game",
        "-project=" .. uproject,
    }
    vim.system(cmd, { cwd = root, text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                local output = (result.stdout or "") .. (result.stderr or "")
                local lines = vim.split(vim.trim(output), "\n")
                local tail = table.concat(vim.list_slice(lines, math.max(1, #lines - 10)), "\n")
                vim.notify("UnrealClangDb failed:\n" .. tail, vim.log.levels.ERROR)
                return
            end

            local database = read_file(root .. "/.vscode/compileCommands_" .. name .. ".json")
            if not database then
                vim.notify("UnrealClangDb: no compileCommands_" .. name .. ".json in .vscode", vim.log.levels.ERROR)
                return
            end
            
            -- the flags live in the .rsp files, so a .Build.cs change can alter them while the JSON stays the same
            local signature = database
            local rsp_files = vim.fn.glob(root .. "/.vscode/compileCommands_" .. name .. "/*.rsp", false, true)
            table.sort(rsp_files)
            for _, rsp in ipairs(rsp_files) do
                signature = signature .. (read_file(rsp) or "")
            end
            if signature == last_db_signature then
                return
            end
            last_db_signature = signature

            local target = root .. "/compile_commands.json"
            if read_file(target) ~= database then
                local file = io.open(target, "wb")
                if file then
                    file:write(database)
                    file:close()
                end
            end
            vim.cmd("lsp restart clangd")
        end)
    end)
end

-- regenerate compile_commands.json via Update-UnrealClangDb from the PowerShell profile
vim.api.nvim_create_user_command("UnrealClangDb", regenerate_clang_db,  { desc = "Regenerate compile_commands.json for the Unreal project" })

local log_buf

local function get_log_buf()
    if log_buf and vim.api.nvim_buf_is_valid(log_buf) then
        return log_buf
    end
    log_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(log_buf, "unreal://build")
    return log_buf
end


-- the bottom split showing the log, ignoring the menu's log float
local function log_split_win()
    for _, win in ipairs(vim.fn.win_findbuf(get_log_buf())) do
        if vim.api.nvim_win_get_config(win).relative == "" then
            return win
        end
    end
    return nil
end

-- skipped when the menu's log float already shows the output
local function show_log()
    if vim.fn.bufwinid(get_log_buf()) ~= -1 then
        return
    end
    local current = vim.api.nvim_get_current_win()
    vim.cmd("botright 15split")
    vim.api.nvim_win_set_buf(0, get_log_buf())
    vim.api.nvim_set_current_win(current)
end

local function append_lines(lines)
    local buf = get_log_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    -- follow the output in every window showing the log: the bottom split and the menu's log column
    local last = vim.api.nvim_buf_line_count(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_set_cursor(win, { last, 0 })
    end
end

local build = nil
local last_build_summary = nil

-- the menu (and later the status line) listens for this instead of being called directly
local function notify_build_changed()
    vim.api.nvim_exec_autocmds("User", { pattern = "UnrealBuildChanged", modeline = false })
end

local function set_log_title(text)
    local win = log_split_win()
    if win then
        vim.wo[win].winbar = text
    end
end


-- UnrealBuildTool prints [done/total] before every action it runs
local function on_build_lines(lines)
    append_lines(lines)
    if not build then
        return
    end
    for _, line in ipairs(lines) do
        local done, total = line:match("^%[(%d+)/(%d+)%]")
        if done then
            build.done, build.total = tonumber(done), tonumber(total)
        end
    end
    if build.total then
        -- winbar treats % as a format character, so it needs %% to print one
        set_log_title(string.format(" Building %s  %d%%%%  (%d/%d)", build.config,
            math.floor(build.done / build.total * 100), build.done, build.total))
        notify_build_changed()
    end
end


-- MSVC:              C:\path\File.cpp(12,5): error C2065: message
-- MSVC, no column:   C:\path\File.cpp(12): fatal error C1083: message
-- Unreal Header Tool: C:\path\File.h(12): Error: message
-- linker errors name an .obj or .dll instead of a source line, so they become error entries with no location
-- everything else, like the source line and ^ marker MSVC prints under a diagnostic, is dropped
local build_errorformat = table.concat({
    "%f(%l\\,%c): fatal %trror %m",
    "%f(%l): fatal %trror %m",
    "%f(%l\\,%c): %t%*[a-z] %m",
    "%f(%l): %t%*[a-z] %m",
    "%f(%l): %t%*[a-zA-Z]: %m",
    "%.%# : fatal %trror LNK%n: %m",
    "%.%# : %trror LNK%n: %m",
    "%-G%.%#",
}, ",")


-- output arrives in arbitrary chunks. hold back the last partial line until the rest of it arrives
local function line_reader()
    local pending = ""
    return function(_, data)
        if not data then
            if pending ~= "" then
                local last = pending
                vim.schedule(function()
                    on_build_lines({ last })
                end)
            end
            return
        end

        pending = pending .. (data:gsub("\r", ""))
        local lines = vim.split(pending, "\n", { plain = true })
        pending = table.remove(lines)
        if #lines > 0 then
            vim.schedule(function()
                on_build_lines(lines)
            end)
        end
    end
end

-- looks up the project and its engine, or notifies and returns nil
local function find_project()
    local uproject = find_uproject()
    if not uproject then
        vim.notify("No .uproject above this file", vim.log.levels.ERROR)
        return nil
    end
    local engine = find_engine_root(uproject)
    if not engine then
        vim.notify("Can't find the engine for " .. uproject, vim.log.levels.ERROR)
        return nil
    end
    return uproject, vim.fs.dirname(uproject), engine
end

local editor = nil

-- tasklist sees every editor, including ones started from Rider or the Epic launcher, but not which project each
-- one has open. The executable name gives the configuration, since DebugGame has an executable of its own
local function find_running_editors(callback)
    vim.system(
        { "tasklist", "/FI", "IMAGENAME eq UnrealEditor*", "/FO", "CSV", "/NH" },
        { text = true },
        function(result)
            local editors = {}
            for line in (result.stdout or ""):gmatch("[^\r\n]+") do
                local name, pid = line:match('^"(UnrealEditor[^"]*%.exe)","(%d+)"')
                -- the -Cmd executables are commandlets (cooking, automation), not an open editor
                if pid and not name:find("-Cmd", 1, true) then
                    table.insert(editors, {
                        pid = tonumber(pid),
                        config = name:find("DebugGame", 1, true) and "DebugGame" or "Development",
                    })
                end
            end
            vim.schedule(function()
                callback(editors)
            end)
        end
    )
end

local function launch_editor(config)
    local uproject, root, engine = find_project()
    if not uproject then
        return
    end

    find_running_editors(function(editors)
        if #editors > 0 then
            vim.notify("An Unreal editor is already running (PID " .. editors[1].pid .. ")", vim.log.levels.WARN)
            return
        end

        -- DebugGame is baked into the executable at compile time; the stock UnrealEditor.exe always loads Development modules
        local exe = config == "DebugGame" and "UnrealEditor-Win64-DebugGame.exe" or "UnrealEditor.exe"
        local cmd = { engine .. "/Engine/Binaries/Win64/" .. exe, uproject }
        local this_editor = { config = config }
        editor = this_editor
        -- detached so closing Neovim doesn't take the editor down with it
        this_editor.handle = vim.system(cmd, { cwd = root, detach = true, stdout = false, stderr = false }, function(result)
            vim.schedule(function()
                if editor == this_editor then
                    editor = nil
                end
                vim.notify("Unreal editor exited (code " .. result.code .. ")")
            end)
        end)
        vim.notify("Launching " .. config .. " editor")
    end)
end

-- without /F, taskkill asks the editor to close, so it can prompt to save; /F kills it outright.
-- Cancelling the save prompt leaves the editor open, so the wait gives up instead of hanging forever
local close_timeout_ms = 90000

local function close_editor(pid, force, on_closed)
    local cmd = { "taskkill", "/PID", tostring(pid) }
    if force then
        table.insert(cmd, 2, "/F")
    end
    vim.system(cmd)

    local deadline = vim.uv.now() + close_timeout_ms
    local function poll()
        find_running_editors(function(editors)
            for _, running in ipairs(editors) do
                if running.pid == pid then
                    if vim.uv.now() > deadline then
                        vim.notify("The editor is still open. If you cancelled the save prompt, nothing else will happen", vim.log.levels.WARN)
                        return
                    end
                    vim.defer_fn(poll, 500)
                    return
                end
            end
            if on_closed then
                on_closed()
            end
        end)
    end
    vim.defer_fn(poll, 500)
end

local function start_build(config, on_success)
    if build then
        vim.notify("A " .. build.config .. " build is already running", vim.log.levels.WARN)
        return
    end

    local uproject, root, engine = find_project()
    if not uproject then
        return
    end
    local target = find_editor_target(root)
    if not target then
        vim.notify("No *Editor.Target.cs in " .. root .. "/Source", vim.log.levels.ERROR)
        return
    end

    -- with an editor open, UnrealBuildTool either refuses (Live Coding) or writes numbered Hot Reload DLLs
    find_running_editors(function(editors)
        if build then
            vim.notify("A " .. build.config .. " build is already running", vim.log.levels.WARN)
            return
        end
        if #editors > 0 then
            vim.notify("Close the Unreal editor first, or use :UnrealBuildRelaunch to close it, build, and relaunch it", vim.log.levels.WARN)
            -- lets a menu that switched to the build layout fall back to its normal entries
            notify_build_changed()
            return
        end

        -- same arguments Rider passes through Build.bat
        local cmd = {
            engine .. "/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe",
            target,
            "Win64",
            config,
            "-Project=" .. uproject,
            "-WaitMutex",
            "-FromMsBuild",
            "-architecture=x64",
        }

        vim.api.nvim_buf_set_lines(get_log_buf(), 0, -1, false, { "> " .. table.concat(cmd, " "), "" })
        show_log()
        set_log_title(" Building " .. config)

        local started = vim.uv.hrtime()
        -- the exit callback checks this object, not `build`, which a restart may already have replaced
        local this_build = { config = config }
        build = this_build
        notify_build_changed()
        this_build.handle = vim.system(
            cmd,
            { cwd = root, stdout = line_reader(), stderr = line_reader() },
            function(result)
                vim.schedule(function()
                    if build == this_build then
                        build = nil
                    end
                    local seconds = (vim.uv.hrtime() - started) / 1e9

                    if this_build.cancelled then
                        local summary = string.format("%s build cancelled after %.0fs", config, seconds)
                        append_lines({ "", summary })
                        set_log_title(" " .. summary)
                        vim.notify(summary, vim.log.levels.WARN)
                        last_build_summary = summary
                        notify_build_changed()
                        if this_build.restart then
                            start_build(config, on_success)
                        end
                        return
                    end

                    local ok = result.code == 0

                    vim.fn.setqflist({}, "r", {
                        title = config .. " build",
                        lines = vim.api.nvim_buf_get_lines(get_log_buf(), 0, -1, false),
                        efm = build_errorformat,
                    })
                    local errors, warnings = 0, 0
                    for _, item in ipairs(vim.fn.getqflist()) do
                        local type = item.type:lower()
                        if type == "e" then
                            errors = errors + 1
                        elseif type == "w" then
                            warnings = warnings + 1
                        end
                    end

                    local summary = string.format(
                        "%s build %s in %.0fs: %d errors, %d warnings",
                        config,
                        ok and "succeeded" or "failed",
                        seconds,
                        errors,
                        warnings
                    )
                    append_lines({ "", summary })
                    set_log_title(" " .. summary)
                    vim.notify(summary, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
                    last_build_summary = summary
                    notify_build_changed()

                    if ok then
                        regenerate_clang_db()
                        if on_success then
                            on_success()
                        end
                    elseif errors > 0 then
                        vim.cmd("copen | wincmd p")
                    end
                end)
            end
        )
    end)
end

-- vim.system():kill() only stops UnrealBuildTool itself; /T takes the compilers and linkers it started down with it
local function cancel_build(restart)
    if not build then
        vim.notify("No build is running", vim.log.levels.INFO)
        return
    end
    if build.cancelled then
        build.restart = build.restart or restart
        return
    end
    build.cancelled = true
    build.restart = restart
    append_lines({ "", restart and "Restarting..." or "Cancelling..." })
    vim.system({ "taskkill", "/T", "/F", "/PID", tostring(build.handle.pid) })
end

local function complete_config()
    return { "Development", "DebugGame" }
end

vim.api.nvim_create_user_command("UnrealBuild", function(opts)
    start_build(opts.args ~= "" and opts.args or "Development")
end, { nargs = "?", complete = complete_config, desc = "Build the Unreal editor target" })

vim.api.nvim_create_user_command("UnrealBuildCancel", function()
    cancel_build(false)
end, { desc = "Cancel the running Unreal build" })

vim.api.nvim_create_user_command("UnrealBuildRestart", function()
    cancel_build(true)
end, { desc = "Cancel the running Unreal build and start it again" })

vim.api.nvim_create_user_command("UnrealEditor", function(opts)
    launch_editor(opts.args ~= "" and opts.args or "Development")
end, { nargs = "?", complete = complete_config, desc = "Launch the Unreal editor for this project" })

vim.api.nvim_create_user_command("UnrealEditorClose", function(opts)
    find_running_editors(function(editors)
        if #editors == 0 then
            vim.notify("No Unreal editor running")
            return
        end
        if #editors > 1 then
            vim.notify("More than one Unreal editor is running; close the right one yourself", vim.log.levels.WARN)
            return
        end
        close_editor(editors[1].pid, opts.bang)
    end)
end, { bang = true, desc = "Close the Unreal editor (! to force-close without saving)" })

-- named so it isn't confused with Rider's Rebuild, which cleans first
vim.api.nvim_create_user_command("UnrealBuildRelaunch", function(opts)
    find_running_editors(function(editors)
        if #editors == 0 then
            local config = opts.args ~= "" and opts.args or "Development"
            start_build(config, function()
                launch_editor(config)
            end)
            return
        end
        if #editors > 1 then
            vim.notify("More than one Unreal editor is running; close the extras first", vim.log.levels.WARN)
            return
        end

        -- rebuild the configuration the editor was running, unless one was given
        local config = opts.args ~= "" and opts.args or editors[1].config
        vim.notify("Closing the editor to build " .. config)
        close_editor(editors[1].pid, false, function()
            start_build(config, function()
                launch_editor(config)
            end)
        end)
    end)
end, { nargs = "?", complete = complete_config, desc = "Close the Unreal editor, build, and relaunch it" })

vim.api.nvim_create_user_command("UnrealEditorStatus", function()
    find_running_editors(function(editors)
        if #editors == 0 then
            vim.notify("No Unreal editor running")
            return
        end
        local lines = {}
        for _, running in ipairs(editors) do
            local origin = (editor and editor.handle.pid == running.pid) and "launched from Neovim" or "started elsewhere"
            table.insert(lines, string.format("PID %d: %s (%s)", running.pid, origin, running.config))
        end
        vim.notify(table.concat(lines, "\n"))
    end)
end, { desc = "Show running Unreal editors" })

vim.api.nvim_create_user_command("UnrealEditorRelaunch", function()
    find_running_editors(function(editors)
        if #editors == 0 then
            vim.notify("No Unreal editor running")
            return
        end
        if #editors > 1 then
            vim.notify("More than one Unreal editor is running; close the extras first", vim.log.levels.WARN)
            return
        end
        local running = editors[1]
        close_editor(running.pid, false, function()
            launch_editor(running.config)
        end)
    end)
end, { desc = "Close the Unreal editor and launch it again without building" })

-- the log lives for the whole session once a build has run, so the menu and :UnrealLog can bring it back
local function has_build_log()
    return build ~= nil or last_build_summary ~= nil
end

-- toggles the log in a bottom split, a normal window that <C-w> moves in and out of
local function toggle_log()
    local win = log_split_win()
    if win then
        if not pcall(vim.api.nvim_win_close, win, false) then
            vim.notify("The build log is the only window left", vim.log.levels.WARN)
        end
        return
    end
    if not has_build_log() then
        vim.notify("No build has run yet")
        return
    end
    vim.cmd("botright 15split")
    vim.api.nvim_win_set_buf(0, get_log_buf())
    if not build then
        vim.wo.winbar = " " .. last_build_summary
    end
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(get_log_buf()), 0 })
end

vim.api.nvim_create_user_command("UnrealLog", toggle_log, { desc = "Open or close the Unreal build log in a bottom split" })

-- menu: a numbered float on <leader>u. Once a build has run, the build log sits in a second float to its left

local menu = nil
local menu_width = 32
local menu_ns = vim.api.nvim_create_namespace("unreal_menu")

-- keep_open entries run inside the menu: it switches to the build layout so the log streams into the float
local function menu_items(state, running)
    local items
    if state == "building" then
        items = {
            { label = "Restart Build", cmd = "UnrealBuildRestart", keep_open = true },
            { label = "Cancel Build", cmd = "UnrealBuildCancel", keep_open = true },
        }
    elseif state == "editor" then
        items = {
            { label = "Rebuild " .. running.config, cmd = "UnrealBuildRelaunch" },
            { label = "Close Editor", cmd = "UnrealEditorClose" },
            { label = "Relaunch Editor", cmd = "UnrealEditorRelaunch" },
            { label = "Force Close Editor", cmd = "UnrealEditorClose!" },
        }
    else
        -- builds before plain launches, and DebugGame first in each group: it's the configuration in daily use
        items = {
            { label = "Build and Run DebugGame", cmd = "UnrealBuildRelaunch DebugGame", keep_open = true },
            { label = "Build DebugGame", cmd = "UnrealBuild DebugGame", keep_open = true },
            { label = "Build and Run Development", cmd = "UnrealBuildRelaunch Development", keep_open = true },
            { label = "Build Development", cmd = "UnrealBuild Development", keep_open = true },
            { label = "Launch Editor DebugGame", cmd = "UnrealEditor DebugGame" },
            { label = "Launch Editor Development", cmd = "UnrealEditor Development" },
        }
    end
    if has_build_log() then
        table.insert(items, { label = log_split_win() and "Close Log Split" or "Open Log Split", cmd = "UnrealLog" })
    end
    return items
end

local function menu_title(state, running)
    if state == "building" then
        return " Unreal: building "
    elseif state == "editor" then
        return " Unreal: " .. running.config .. " editor "
    end
    return " Unreal "
end

-- float titles are plain text, so unlike the winbar a single % prints as is
local function log_title()
    if build then
        if build.total then
            return string.format(" Building %s  %d%%  (%d/%d) ", build.config,
                math.floor(build.done / build.total * 100), build.done, build.total)
        end
        return " Building " .. build.config .. " "
    end
    return " " .. (last_build_summary or "Build log") .. " "
end

-- leave the border to the global 'winborder' when it's set. Float titles need a border, so "none" gets one too
local function float_border()
    local global = vim.o.winborder
    return (global == "" or global == "none") and "rounded" or nil
end

local function close_menu()
    if not menu then
        return
    end
    local m = menu
    menu = nil
    if m.timer then
        m.timer:stop()
        m.timer:close()
    end
    pcall(vim.api.nvim_del_augroup_by_id, m.augroup)
    for _, win in ipairs({ m.menu_win, m.log_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
end

local function render_menu(m)
    local lines = {}
    for i, item in ipairs(m.items) do
        lines[i] = string.format(" %d  %s", i, item.label)
    end
    vim.bo[m.buf].modifiable = true
    vim.api.nvim_buf_set_lines(m.buf, 0, -1, false, lines)
    vim.bo[m.buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(m.buf, menu_ns, 0, -1)
    for i = 1, #m.items do
        vim.api.nvim_buf_set_extmark(m.buf, menu_ns, i - 1, 1, { end_col = 2, hl_group = "Number" })
    end

    vim.api.nvim_win_set_config(m.menu_win, { height = #m.items, title = menu_title(m.state, m.running) })
    local line = math.min(vim.api.nvim_win_get_cursor(m.menu_win)[1], #m.items)
    vim.api.nvim_win_set_cursor(m.menu_win, { line, 0 })
end

local function open_menu(state, running)
    close_menu()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "unrealmenu"
    local m = { buf = buf, state = state, running = running, items = menu_items(state, running) }
    menu = m

    local border = float_border()
    local height = #m.items
    local row = math.floor((vim.o.lines - height) / 2) - 1
    local col = math.floor((vim.o.columns - menu_width) / 2)

    if state == "building" or has_build_log() then
        -- the log on the left, the menu on the right, both vertically centered on the log
        local total_width = math.min(vim.o.columns - 8, 160)
        local log_height = math.min(vim.o.lines - 8, 30)
        local log_width = total_width - menu_width - 5
        row = math.floor((vim.o.lines - log_height) / 2) - 1
        local log_col = math.floor((vim.o.columns - total_width) / 2)
        col = log_col + log_width + 3

        local log_buf = get_log_buf()
        m.log_win = vim.api.nvim_open_win(log_buf, false, {
            relative = "editor",
            row = row,
            col = log_col,
            width = log_width,
            height = log_height,
            style = "minimal",
            border = border,
            title = log_title(),
        })
        vim.wo[m.log_win].wrap = true
        vim.api.nvim_win_set_cursor(m.log_win, { vim.api.nvim_buf_line_count(log_buf), 0 })
    end

    m.menu_win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = menu_width,
        height = height,
        style = "minimal",
        border = border,
        title = menu_title(state, running),
    })
    vim.wo[m.menu_win].cursorline = true
    render_menu(m)

    local function run(index)
        local item = m.items[index]
        if not item then
            return
        end
        if not item.keep_open then
            close_menu()
        elseif m.state ~= "building" then
            -- open the log float before the build starts, so show_log finds it and skips the bottom split
            open_menu("building")
        end
        vim.cmd(item.cmd)
    end

    local function move(delta)
        local line = vim.api.nvim_win_get_cursor(m.menu_win)[1] + delta
        vim.api.nvim_win_set_cursor(m.menu_win, { math.max(1, math.min(line, #m.items)), 0 })
    end

    local function map(keys, fn)
        for _, key in ipairs(keys) do
            vim.keymap.set("n", key, fn, { buffer = buf, nowait = true })
        end
    end

    for i = 1, 9 do
        map({ tostring(i) }, function()
            run(i)
        end)
    end
    map({ "j", "<Down>" }, function()
        move(1)
    end)
    map({ "k", "<Up>" }, function()
        move(-1)
    end)
    map({ "<CR>" }, function()
        run(vim.api.nvim_win_get_cursor(m.menu_win)[1])
    end)
    map({ "q", "<Esc>" }, close_menu)

    -- <C-w> commands skip floats, so moving between the menu and the log float needs its own keys
    local function focus_log()
        if m.log_win and vim.api.nvim_win_is_valid(m.log_win) then
            vim.api.nvim_set_current_win(m.log_win)
        end
    end
    map({ "<C-w>h", "<C-w><Left>", "<C-w>w", "<C-w><C-w>", "<Tab>" }, focus_log)

    if m.log_win then
        -- the log buffer is shared with the bottom split, so each key only acts while the cursor is in the menu's float
        local log_buf = get_log_buf()
        local function in_log_float()
            return menu ~= nil and vim.api.nvim_get_current_win() == menu.log_win
        end
        local function to_menu_or(fallback)
            return function()
                if in_log_float() then
                    vim.api.nvim_set_current_win(menu.menu_win)
                else
                    vim.cmd(fallback)
                end
            end
        end
        vim.keymap.set("n", "<C-w>l", to_menu_or("wincmd l"), { buffer = log_buf })
        vim.keymap.set("n", "<C-w><Right>", to_menu_or("wincmd l"), { buffer = log_buf })
        vim.keymap.set("n", "<C-w>w", to_menu_or("wincmd w"), { buffer = log_buf })
        vim.keymap.set("n", "<C-w><C-w>", to_menu_or("wincmd w"), { buffer = log_buf })
        -- expr mappings can't close windows directly, so the close is scheduled and the key swallowed
        for _, key in ipairs({ "q", "<Esc>" }) do
            vim.keymap.set("n", key, function()
                if in_log_float() then
                    vim.schedule(close_menu)
                    return ""
                end
                return key
            end, { buffer = log_buf, expr = true, nowait = true })
        end
    end

    m.augroup = vim.api.nvim_create_augroup("unreal_menu", { clear = true })
    -- moving to any window other than the menu or its log float closes both, so no float is left behind
    vim.api.nvim_create_autocmd("WinEnter", {
        group = m.augroup,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if win == m.menu_win or win == m.log_win then
                return
            end
            -- only this menu: switching to the build layout replaces it, and that must not close the new one
            vim.schedule(function()
                if menu == m then
                    close_menu()
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", { group = m.augroup, callback = close_menu })

    -- editors start and exit outside Neovim's view (a soft close takes a few seconds), so poll while the menu is open
    m.timer = vim.uv.new_timer()
    m.timer:start(1000, 1000, vim.schedule_wrap(function()
        if menu ~= m or build or m.state == "building" or m.checking then
            return
        end
        m.checking = true
        find_running_editors(function(editors)
            m.checking = false
            if menu ~= m or build or m.state == "building" then
                return
            end
            local state = #editors > 0 and "editor" or "idle"
            local config = editors[1] and editors[1].config
            if state ~= m.state or (m.running and m.running.config) ~= config then
                m.state, m.running = state, editors[1]
                m.items = menu_items(state, editors[1])
                render_menu(m)
            end
        end)
    end))
    vim.api.nvim_create_autocmd("User", {
        group = m.augroup,
        pattern = "UnrealBuildChanged",
        callback = function()
            if menu ~= m then
                return
            end
            if m.log_win and vim.api.nvim_win_is_valid(m.log_win) then
                vim.api.nvim_win_set_config(m.log_win, { title = log_title() })
            end
            -- the entries follow `build` both ways. A restart ends one build and starts the next,
            -- so the menu can briefly see "no build" and has to switch back when the new one starts
            if build then
                if m.state ~= "building" then
                    m.state, m.running = "building", nil
                    m.items = menu_items("building")
                    render_menu(m)
                end
            elseif m.state == "building" then
                -- the build finished: switch the entries over, keeping the log column so the result stays readable
                find_running_editors(function(editors)
                    -- a restart may have started the next build while tasklist ran
                    if menu ~= m or build then
                        return
                    end
                    m.state = #editors > 0 and "editor" or "idle"
                    m.running = editors[1]
                    m.items = menu_items(m.state, m.running)
                    render_menu(m)
                end)
            end
        end,
    })
end

local function open_unreal_menu()
    if build then
        open_menu("building")
        return
    end
    find_running_editors(function(editors)
        if build then
            open_menu("building")
        elseif #editors > 0 then
            open_menu("editor", editors[1])
        else
            open_menu("idle")
        end
    end)
end

vim.api.nvim_create_user_command("UnrealMenu", open_unreal_menu, { desc = "Open the Unreal build menu" })
vim.keymap.set("n", "<leader>u", open_unreal_menu, { desc = "Unreal build menu" })
