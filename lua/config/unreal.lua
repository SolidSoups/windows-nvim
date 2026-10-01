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
            local rsp_files = vim.fn.glob(root .. "/.vscode/compileCommands_" .. name .. "*.rsp", false, true)
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


local function show_log()
    local buf = get_log_buf()
    if vim.fn.bufwinid(buf) ~= -1 then
        return
    end
    local current = vim.api.nvim_get_current_win()
    vim.cmd("botright 15split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_set_current_win(current)
end

local function append_lines(lines)
    local buf = get_log_buf()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
end

local build = nil

local function set_log_title(text)
    local win = vim.fn.bufwinid(get_log_buf())
    if win ~= -1 then
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
    end
end


-- MSVC:              C:\path\File.cpp(12,5): error C2065: message
-- MSVC, no column:   C:\path\File.cpp(12): fatal error C1083: message
-- Unreal Header Tool: C:\path\File.h(12): Error: message
-- linker errors have no source location, so they're kept as text-only entries
-- everything else, like the source line and ^ marker MSVC prints under a diagnostic, is dropped
local build_errorformat = table.concat({
    "%f(%l\\,%c): fatal %trror %m",
    "%f(%l): fatal %trror %m",
    "%f(%l\\,%c): %t%*[a-z] %m",
    "%f(%l): %t%*[a-z] %m",
    "%f(%l): %t%*[a-zA-Z]: %m",
    "%+G%.%#error LNK%.%#",
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


vim.api.nvim_create_user_command("UnrealBuild", function(opts)
    if build then
        vim.notify("A " .. build.config .. " build is already running", vim.log.levels.WARN)
        return
    end

    local config = opts.args ~= "" and opts.args or "Development"
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
    local target = find_editor_target(root)
    if not target then
        vim.notify("No *Editor.Target.cs in " .. root .. "/Source", vim.log.levels.ERROR)
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
    build = { config = config }
    build.handle = vim.system(
        cmd,
        { cwd = root, stdout = line_reader(), stderr = line_reader() },
        function(result)
            vim.schedule(function()
                build = nil
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
                    (vim.uv.hrtime() - started) / 1e9,
                    errors,
                    warnings
                )
                append_lines({ "", summary })
                set_log_title(" " .. summary)
                vim.notify(summary, ok and vim.log.levels.INFO or vim.log.levels.ERROR)

                if ok then
                    regenerate_clang_db()
                elseif errors > 0 then
                    vim.cmd("copen | wincmd p")
                end
            end)
        end)
end, {
    nargs = "?",
    complete = function()
        return { "Development", "DebugGame" }
    end,
    desc = "Build the Unreal editor target",
})
