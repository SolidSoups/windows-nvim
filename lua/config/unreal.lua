-- project and plugin descriptors are plain JSON
vim.filetype.add({
	extension = {
		uproject = "json",
		uplugin = "json",
	},
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

-- :lsp restart only reattaches the buffers the old client had when it exited, so overlapping restarts
-- (startup refresh, build finished) or a file opened mid-restart can leave buffers without clangd.
-- Disabling and re-enabling the config instead attaches clangd to every loaded C++ buffer
local clangd_restarting = false
local clangd_restart_pending = false

local function restart_clangd()
	if clangd_restarting then
		clangd_restart_pending = true
		return
	end
	clangd_restarting = true
	local old_clients = vim.lsp.get_clients({ name = "clangd" })
	vim.lsp.enable("clangd", false)

	-- re-enable only once Neovim has dropped the old client. is_stopped() turns true while the process is still
	-- exiting, and re-enabling then briefly runs two clangd processes side by side. A clangd busy building its
	-- precompiled header (common right after startup) can ignore the shutdown request for a long time, so after
	-- the grace period it's killed rather than left running next to the new one
	local grace_ms, kill_wait_ms = 5000, 5000
	local started = vim.uv.now()
	local killed = false
	local function finish()
		local alive = {}
		for _, client in ipairs(old_clients) do
			if vim.lsp.get_client_by_id(client.id) then
				table.insert(alive, client)
			end
		end
		local waited = vim.uv.now() - started
		if #alive > 0 and waited < grace_ms + kill_wait_ms then
			if not killed and waited >= grace_ms then
				killed = true
				for _, client in ipairs(alive) do
					client:stop(true)
				end
			end
			vim.defer_fn(finish, 100)
			return
		end
		vim.lsp.enable("clangd")
		clangd_restarting = false
		if clangd_restart_pending then
			clangd_restart_pending = false
			restart_clangd()
		end
	end
	finish()
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

-- what clangd's flags depend on: each source file and a hash of its .rsp. The generator renumbers the .rsp files
-- between runs (GameAnalyticsEditor.4.rsp becomes .5), so comparing the raw JSON would restart clangd for nothing
local function db_signature(database_path)
	local content = read_file(database_path)
	local ok, entries = pcall(vim.json.decode, content or "")
	if not ok or type(entries) ~= "table" then
		return nil
	end
	local rsp_hashes = {}
	local parts = {}
	for _, entry in ipairs(entries) do
		local rsp = entry.arguments and entry.arguments[2]
		rsp = rsp and rsp:gsub("^@", "")
		if rsp and not rsp_hashes[rsp] then
			rsp_hashes[rsp] = vim.fn.sha256(read_file(rsp) or "")
		end
		table.insert(parts, (entry.file or "") .. "|" .. (rsp and rsp_hashes[rsp] or ""))
	end
	table.sort(parts)
	return table.concat(parts, "\n")
end

-- force_restart restarts clangd even when the database is unchanged, so it rereads regenerated headers
local function regenerate_clang_db(force_restart)
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

	-- first run this session: the baseline is the database clangd started with, read before it gets rewritten
	if last_db_signature == nil then
		last_db_signature = db_signature(root .. "/compile_commands.json")
	end

	local cmd = {
		engine .. "/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe",
		"-projectfiles",
		"-vscode",
		"-game",
		"-project=" .. uproject,
		-- a header refresh that finishes as a build starts would otherwise hit the build's mutex and fail
		"-WaitMutex",
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

			local generated = root .. "/.vscode/compileCommands_" .. name .. ".json"
			local database = read_file(generated)
			local signature = db_signature(generated)
			if not database or not signature then
				vim.notify(
					"UnrealClangDb: no usable compileCommands_" .. name .. ".json in .vscode",
					vim.log.levels.ERROR
				)
				return
			end

			-- always keep the copy current, since the .rsp names inside it change even when the flags don't
			local target = root .. "/compile_commands.json"
			if read_file(target) ~= database then
				local file = io.open(target, "wb")
				if file then
					file:write(database)
					file:close()
				end
			end

			-- the flags live in the .rsp files, so a .Build.cs change can alter them while the file list stays the same
			local changed = signature ~= last_db_signature
			last_db_signature = signature
			if changed or force_restart then
				restart_clangd()
			end
		end)
	end)
end

vim.api.nvim_create_user_command("UnrealClangDb", function()
	regenerate_clang_db(true)
end, { desc = "Regenerate compile_commands.json for the Unreal project" })

local log_buf

local function get_log_buf()
	if log_buf and vim.api.nvim_buf_is_valid(log_buf) then
		return log_buf
	end
	log_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(log_buf, "unreal://build")
	vim.bo[log_buf].filetype = "unrealbuild"
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
-- the status line reads this; nil after a cancel, so a cancelled build shows nothing
local last_build_result = nil

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
		set_log_title(
			string.format(
				" Building %s  %d%%%%  (%d/%d)",
				build.config,
				math.floor(build.done / build.total * 100),
				build.done,
				build.total
			)
		)
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

-- on_launched(pid) runs once the editor process exists, for attaching the debugger from its first moment
local function launch_editor(config, on_launched)
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
		this_editor.handle = vim.system(
			cmd,
			{ cwd = root, detach = true, stdout = false, stderr = false },
			function(result)
				vim.schedule(function()
					if editor == this_editor then
						editor = nil
					end
					vim.notify("Unreal editor exited (code " .. result.code .. ")")
				end)
			end
		)
		vim.notify("Launching " .. config .. " editor")
		if on_launched then
			on_launched(this_editor.handle.pid)
		end
	end)
end

-- package.loaded checks for nvim-dap without loading it, so editor commands don't pull it in just to ask
local function debugging()
	local dap = package.loaded.dap
	return dap ~= nil and dap.session() ~= nil
end

-- terminateDebuggee = false detaches and leaves the editor running. dap.terminate() would kill it
local function detach_debugger(on_done)
	if not debugging() then
		if on_done then
			on_done()
		end
		return
	end
	package.loaded.dap.disconnect({ terminateDebuggee = false }, on_done)
end

vim.api.nvim_create_user_command("UnrealDetach", function()
	detach_debugger()
end, { desc = "Detach the debugger and leave the Unreal editor running" })

-- Windows kills a debugged process when its debugger exits, and lldb-dap exits with Neovim. Detach first,
-- and wait for it, since Neovim won't run callbacks once VimLeavePre returns
vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("unreal_debug", { clear = true }),
	callback = function()
		local done = false
		detach_debugger(function()
			done = true
		end)
		vim.wait(5000, function()
			return done
		end, 50)
	end,
})

-- without /F, taskkill asks the editor to close, so it can prompt to save; /F kills it outright.
-- Cancelling the save prompt leaves the editor open, so the wait gives up instead of hanging forever
local close_timeout_ms = 90000

local function close_editor(pid, force, on_closed)
	-- an editor paused at a breakpoint can't answer the close request, so let it run first
	detach_debugger(function()
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
							vim.notify(
								"The editor is still open. If you cancelled the save prompt, nothing else will happen",
								vim.log.levels.WARN
							)
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
	end)
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
			vim.notify(
				"Close the Unreal editor first, or use :UnrealBuildRelaunch to close it, build, and relaunch it",
				vim.log.levels.WARN
			)
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

		-- the log shows in the menu, which opens itself on the build's first UnrealBuildChanged
		vim.api.nvim_buf_set_lines(get_log_buf(), 0, -1, false, { "> " .. table.concat(cmd, " "), "" })
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
						last_build_result = nil
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
					last_build_result = { ok = ok, config = config, errors = errors, finished = vim.uv.now() }
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

-- Unreal's LLDB formatters show FString, FName, TArray, TMap, ... as values instead of raw structs. The
-- 2ByteChars variant matches Windows, where TCHAR is 2 bytes. Loading it with "command script import" runs its
-- __lldb_init_module, which registers each formatter from Python with debugger.HandleCommand, and that call
-- crashes lldb-dap on Windows (0xC0000409, LLVM 23.1.1). So import it as a plain Python module, which skips
-- __lldb_init_module, and send its registration commands as ordinary LLDB commands instead. They point at
-- lldb/unreal_formatters.py in this config, which wraps Unreal's providers (that file says why)
local function formatter_commands(engine)
	-- forward slashes, since Python and LLDB read a backslash inside quotes as an escape
	local dir = engine:gsub("\\", "/") .. "/Engine/Extras/LLDBDataFormatters"
	local wrapper_dir = vim.fn.stdpath("config"):gsub("\\", "/") .. "/lldb"
	local file = io.open(dir .. "/UEDataFormatters_2ByteChars.py", "r")
	if not file then
		return {}
	end
	local source = file:read("*a")
	file:close()
	local commands = {
		"script import sys; sys.path[0:0] = ['" .. wrapper_dir .. "', '" .. dir .. "']; import unreal_formatters",
	}
	-- read from the script rather than copied here, so an engine update that adds formatters is picked up
	for _, command in source:gmatch("HandleCommand%(([\"'])(.-)%1%)") do
		table.insert(commands, (command:gsub("UEDataFormatters_2ByteChars%.", "unreal_formatters.")))
	end
	-- the wrapper's own additions: enum names for TEnumAsByte, one-line vectors and rotators
	table.insert(commands, [[type summary add -F unreal_formatters.TEnumAsByteSummaryProvider -x "^TEnumAsByte<.+>$" -w UEDataFormatters]])
	table.insert(commands, [[type summary add -F unreal_formatters.MathSummaryProvider -e -x "^UE::Math::(TVector|TVector2|TVector4|TRotator|TQuat)<.+>$" -w UEDataFormatters]])
	return commands
end

-- nvim-dap sends breakpoints set before this when the session starts
local function attach_to(pid, config)
	local _, _, engine = find_project()
	if not engine then
		return
	end
	-- a second dap.run with the same name restarts the session, and a restart can end the editor
	if debugging() then
		vim.notify("The debugger is already attached", vim.log.levels.WARN)
		return
	end
	require("dap").run({
		name = "Unreal editor (" .. config .. ")",
		type = "lldb",
		request = "attach",
		pid = pid,
		initCommands = formatter_commands(engine),
	})
end

vim.api.nvim_create_user_command("UnrealAttach", function()
	find_running_editors(function(editors)
		if #editors == 0 then
			vim.notify("No Unreal editor running", vim.log.levels.WARN)
			return
		end
		attach_to(editors[1].pid, editors[1].config)
	end)
end, { desc = "Attach the debugger to the running Unreal editor" })

-- for launch_editor: attaches as soon as the new editor exists, so breakpoints in startup code hit too
local function attach_on_launch(config)
	return function(pid)
		attach_to(pid, config)
	end
end

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

-- closes a running editor, builds, and launches it again. debug attaches the debugger to the new editor, and a
-- rebuild started while attached stays attached
local function build_and_launch(config_arg, debug)
	local attach = debug or debugging()
	find_running_editors(function(editors)
		if #editors == 0 then
			local config = config_arg ~= "" and config_arg or "Development"
			start_build(config, function()
				launch_editor(config, attach and attach_on_launch(config) or nil)
			end)
			return
		end
		if #editors > 1 then
			vim.notify("More than one Unreal editor is running; close the extras first", vim.log.levels.WARN)
			return
		end

		-- rebuild the configuration the editor was running, unless one was given
		local config = config_arg ~= "" and config_arg or editors[1].config
		vim.notify("Closing the editor to build " .. config)
		close_editor(editors[1].pid, false, function()
			start_build(config, function()
				launch_editor(config, attach and attach_on_launch(config) or nil)
			end)
		end)
	end)
end

-- named so it isn't confused with Rider's Rebuild, which cleans first
vim.api.nvim_create_user_command("UnrealBuildRelaunch", function(opts)
	build_and_launch(opts.args, false)
end, { nargs = "?", complete = complete_config, desc = "Close the Unreal editor, build, and relaunch it" })

vim.api.nvim_create_user_command("UnrealBuildDebug", function(opts)
	build_and_launch(opts.args, true)
end, {
	nargs = "?",
	complete = complete_config,
	desc = "Build, launch the Unreal editor, and attach the debugger (closes a running editor first)",
})

vim.api.nvim_create_user_command("UnrealEditorStatus", function()
	find_running_editors(function(editors)
		if #editors == 0 then
			vim.notify("No Unreal editor running")
			return
		end
		local lines = {}
		for _, running in ipairs(editors) do
			local origin = (editor and editor.handle.pid == running.pid) and "launched from Neovim"
				or "started elsewhere"
			table.insert(lines, string.format("PID %d: %s (%s)", running.pid, origin, running.config))
		end
		vim.notify(table.concat(lines, "\n"))
	end)
end, { desc = "Show running Unreal editors" })

-- after a branch switch the .generated.h files still belong to the old branch, and clangd reports errors
-- everywhere until a build runs Unreal Header Tool. -SkipBuild runs everything before compiling, header
-- generation included, and stops there. Same arguments as a real build, so its flag files stay identical
local refreshing = false

-- a refresh asked for while one is running (another save) runs once more afterwards, so no edit is missed
local refresh_pending = false

-- opts.manual: say why when skipped. opts.quiet: no "Regenerating" message (saves happen often)
local function refresh_generated_headers(opts)
	opts = opts or {}
	local function skipped(reason)
		if opts.manual then
			vim.notify("UnrealRefresh skipped: " .. reason, vim.log.levels.WARN)
		end
	end
	if refreshing then
		refresh_pending = true
		return
	end
	if build then
		skipped("a build is running, and it regenerates the headers itself")
		return
	end
	local uproject, root, engine = find_project()
	if not uproject then
		return
	end
	local target = find_editor_target(root)
	if not target then
		return
	end

	find_running_editors(function()
		if build or refreshing then
			return
		end
		if not opts.quiet then
			vim.notify("Regenerating Unreal headers")
		end
		local cmd = {
			engine .. "/Engine/Binaries/DotNET/UnrealBuildTool/UnrealBuildTool.exe",
			target,
			"Win64",
			"DebugGame",
			"-Project=" .. uproject,
			"-WaitMutex",
			"-FromMsBuild",
			"-architecture=x64",
			"-SkipBuild",
		}
		-- the flag goes on only once the process is running. An error or Ctrl-C before that would leave it
		-- on, and every later refresh would queue behind a run that never finishes
		local ok, err = pcall(vim.system, cmd, { cwd = root, text = true }, function(result)
			vim.schedule(function()
				refreshing = false
				if result.code ~= 0 then
					local output = (result.stdout or "") .. (result.stderr or "")
					local lines = vim.split(vim.trim(output), "\n")
					local tail = table.concat(vim.list_slice(lines, math.max(1, #lines - 10)), "\n")
					vim.notify("Regenerating Unreal headers failed:\n" .. tail, vim.log.levels.WARN)
				else
					-- restarting clangd throws away its precompiled header, and one busy rebuilding it gets killed.
					-- A didSave instead makes clangd recheck every open file's includes, which picks up the new
					-- .generated.h; the save that triggered this refresh went out before the header tool ran
					regenerate_clang_db(false)
					for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
						local buf = next(client.attached_buffers)
						if buf then
							client:notify("textDocument/didSave", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
						end
					end
				end
				if refresh_pending then
					refresh_pending = false
					refresh_generated_headers({ quiet = true })
				end
			end)
		end)
		if ok then
			refreshing = true
		else
			vim.notify("Regenerating Unreal headers failed: " .. tostring(err), vim.log.levels.WARN)
		end
	end)
end

vim.api.nvim_create_user_command("UnrealRefresh", function()
	refresh_generated_headers({ manual = true })
end, {
	desc = "Regenerate Unreal's generated headers and compile_commands.json without compiling",
})

local refresh_group = vim.api.nvim_create_augroup("unreal_startup", { clear = true })

-- opening Neovim in the project is when stale headers from a branch switch show up
vim.api.nvim_create_autocmd("VimEnter", {
	group = refresh_group,
	callback = function()
		if find_unreal_root() then
			refresh_generated_headers()
		end
	end,
})

-- GENERATED_BODY() expands to a macro named after its line, so saving a reflected header with lines added or
-- removed above it leaves the generated header pointing at the old line. Refresh after the saves pause
local save_timer = nil

vim.api.nvim_create_autocmd("BufWritePost", {
	group = refresh_group,
	pattern = { "*.h", "*.hpp" },
	callback = function(args)
		if not find_unreal_root() then
			return
		end
		local reflected = false
		for _, line in ipairs(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)) do
			if line:find("GENERATED_BODY", 1, true) then
				reflected = true
				break
			end
		end
		if not reflected then
			return
		end
		if save_timer then
			save_timer:stop()
		else
			save_timer = vim.uv.new_timer()
		end
		save_timer:start(
			1500,
			0,
			vim.schedule_wrap(function()
				refresh_generated_headers({ quiet = true })
			end)
		)
	end,
})

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
		-- close_editor detaches, so ask now whether to attach to the new editor
		local attach = debugging()
		close_editor(running.pid, false, function()
			launch_editor(running.config, attach and attach_on_launch(running.config) or nil)
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

vim.api.nvim_create_user_command(
	"UnrealLog",
	toggle_log,
	{ desc = "Open or close the Unreal build log in a bottom split" }
)

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
			debugging() and { label = "Detach Debugger", cmd = "UnrealDetach" }
				or { label = "Attach Debugger", cmd = "UnrealAttach" },
			-- Rebuild and Relaunch reattach when the debugger was attached
			{ label = "Rebuild " .. running.config, cmd = "UnrealBuildRelaunch" },
			{ label = "Close Editor", cmd = "UnrealEditorClose" },
			{ label = "Relaunch Editor", cmd = "UnrealEditorRelaunch" },
			{ label = "Force Close Editor", cmd = "UnrealEditorClose!" },
		}
	else
		-- debugging first, then builds before plain launches, DebugGame first in each group: it's the configuration
		-- in daily use
		items = {
			{ label = "Build and Debug DebugGame", cmd = "UnrealBuildDebug DebugGame", keep_open = true },
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
			return string.format(
				" Building %s  %d%%  (%d/%d) ",
				build.config,
				math.floor(build.done / build.total * 100),
				build.done,
				build.total
			)
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
			-- switch to the build layout right away, so the log is on screen before the build's first line
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
	-- a font size change (Ctrl+/Ctrl- in the terminal) resizes Neovim; redraw at the new size and keep the
	-- cursor in both floats, and focus where it was
	vim.api.nvim_create_autocmd("VimResized", {
		group = m.augroup,
		callback = function()
			vim.schedule(function()
				if menu ~= m then
					return
				end
				local menu_line = vim.api.nvim_win_get_cursor(m.menu_win)[1]
				local log_valid = m.log_win and vim.api.nvim_win_is_valid(m.log_win)
				local log_cursor = log_valid and vim.api.nvim_win_get_cursor(m.log_win)
				local log_focused = log_valid and vim.api.nvim_get_current_win() == m.log_win

				open_menu(m.state, m.running)
				local new = menu
				if not new then
					return
				end
				vim.api.nvim_win_set_cursor(new.menu_win, { math.min(menu_line, #new.items), 0 })
				if log_cursor and new.log_win then
					pcall(vim.api.nvim_win_set_cursor, new.log_win, log_cursor)
					if log_focused then
						vim.api.nvim_set_current_win(new.log_win)
					end
				end
			end)
		end,
	})

	-- editors start and exit outside Neovim's view (a soft close takes a few seconds), so poll while the menu is open
	m.timer = vim.uv.new_timer()
	m.timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
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
		end)
	)
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

-- every build shows in the menu, however it started (Rebuild, :UnrealBuild, a restart). It acts only on a
-- build's first event, so closing the menu mid-build keeps it closed until the next build
vim.api.nvim_create_autocmd("User", {
	group = vim.api.nvim_create_augroup("unreal_build_menu", { clear = true }),
	pattern = "UnrealBuildChanged",
	callback = function()
		if not build or build.shown then
			return
		end
		build.shown = true
		if not menu or not menu.log_win then
			open_menu("building")
		end
	end,
})

-- new class: <leader>y in an oil buffer opens a numbered float of parent classes, asks for the name, writes
-- Name.h and Name.cpp side by side in that directory, then refreshes the generated headers and clangd

-- the lifecycle overrides each kind of parent gets, the same ones the editor's New C++ Class wizard writes
local class_kinds = {
	actor = {
		header = [[

public:
	{CLASS}();

protected:
	virtual void BeginPlay() override;

public:
	virtual void Tick(float DeltaTime) override;
]],
		source = [[

{CLASS}::{CLASS}()
{
	PrimaryActorTick.bCanEverTick = true;
}

void {CLASS}::BeginPlay()
{
	Super::BeginPlay();
}

void {CLASS}::Tick(float DeltaTime)
{
	Super::Tick(DeltaTime);
}
]],
	},
	component = {
		-- without BlueprintSpawnableComponent the component never shows in a Blueprint's Add Component list
		specifiers = "ClassGroup=(Custom), meta=(BlueprintSpawnableComponent)",
		header = [[

public:
	{CLASS}();

protected:
	virtual void BeginPlay() override;

public:
	virtual void TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction) override;
]],
		source = [[

{CLASS}::{CLASS}()
{
	PrimaryComponentTick.bCanEverTick = true;
}

void {CLASS}::BeginPlay()
{
	Super::BeginPlay();
}

void {CLASS}::TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction)
{
	Super::TickComponent(DeltaTime, TickType, ThisTickFunction);
}
]],
	},
	widget = {
		header = [[

protected:
	virtual void NativeConstruct() override;
]],
		source = [[

void {CLASS}::NativeConstruct()
{
	Super::NativeConstruct();
}
]],
	},
	subsystem = {
		header = [[

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;
]],
		source = [[

void {CLASS}::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
}

void {CLASS}::Deinitialize()
{
	Super::Deinitialize();
}
]],
	},
}

-- parents without a kind get an empty class body. UUserWidget needs "UMG" in the module's .Build.cs to link
local class_parents = {
	{ name = "AActor", include = "GameFramework/Actor.h", kind = "actor" },
	{ name = "UActorComponent", include = "Components/ActorComponent.h", kind = "component" },
	{ name = "USceneComponent", include = "Components/SceneComponent.h", kind = "component" },
	{ name = "ACharacter", include = "GameFramework/Character.h", kind = "actor" },
	{ name = "APawn", include = "GameFramework/Pawn.h", kind = "actor" },
	{ name = "UObject", include = "UObject/Object.h" },
	{ name = "AGameModeBase", include = "GameFramework/GameModeBase.h" },
	{ name = "APlayerController", include = "GameFramework/PlayerController.h" },
	{ name = "UUserWidget", include = "Blueprint/UserWidget.h", kind = "widget" },
	{ name = "UWorldSubsystem", include = "Subsystems/WorldSubsystem.h", kind = "subsystem" },
}

-- Unreal Header Tool rejects a header whose .generated.h isn't the last include
local class_header = [[
#pragma once

#include "CoreMinimal.h"
#include "{INCLUDE}"
#include "{NAME}.generated.h"

UCLASS({SPECIFIERS})
class {API} {CLASS} : public {PARENT}
{
	GENERATED_BODY()
{BODY}};
]]

local class_source = [[
#include "{NAME}.h"
{BODY}]]

-- gsub looks each placeholder up in vars and leaves unknown ones as they are
local function fill(template, vars)
	return (template:gsub("{(%u+)}", vars))
end

local function write_class(dir, module, parent, name)
	local header_path = dir .. "/" .. name .. ".h"
	local source_path = dir .. "/" .. name .. ".cpp"
	if vim.uv.fs_stat(header_path) or vim.uv.fs_stat(source_path) then
		vim.notify("UnrealNewClass: " .. name .. " already exists here", vim.log.levels.ERROR)
		return
	end

	local kind = class_kinds[parent.kind] or {}
	local vars = {
		NAME = name,
		CLASS = parent.name:sub(1, 1) .. name,
		PARENT = parent.name,
		INCLUDE = parent.include,
		API = module:upper() .. "_API",
		SPECIFIERS = kind.specifiers or "",
	}
	-- gsub doesn't rescan what it inserts, so a body's own {CLASS} placeholders are filled before it goes in
	vars.BODY = fill(kind.header or "", vars)
	local header = fill(class_header, vars)
	vars.BODY = fill(kind.source or "", vars)
	local source = fill(class_source, vars)

	for path, content in pairs({ [header_path] = header, [source_path] = source }) do
		local file = io.open(path, "w")
		if not file then
			vim.notify("UnrealNewClass: can't write " .. path, vim.log.levels.ERROR)
			return
		end
		file:write(content)
		file:close()
	end

	-- the refresh finds the project from the current buffer, and an oil:// buffer name has no .uproject above it
	vim.cmd.edit(vim.fn.fnameescape(header_path))
	refresh_generated_headers({ manual = true })
end

local parent_keys = "1234567890"

-- same look as the build menu: a numbered float, picked with the number, or j/k and <CR>
local function pick_parent(on_pick)
	local title = " New Unreal class "
	local lines = {}
	local width = #title
	for i, parent in ipairs(class_parents) do
		lines[i] = string.format(" %s  %s ", parent_keys:sub(i, i), parent.name)
		width = math.max(width, #lines[i])
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	for i = 1, #lines do
		vim.api.nvim_buf_set_extmark(buf, menu_ns, i - 1, 1, { end_col = 2, hl_group = "Number" })
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - #lines) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = #lines,
		style = "minimal",
		border = float_border(),
		title = title,
	})
	vim.wo[win].cursorline = true

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	local function pick(index)
		local parent = class_parents[index]
		if parent then
			close()
			on_pick(parent)
		end
	end
	local function map(key, fn)
		vim.keymap.set("n", key, fn, { buffer = buf, nowait = true })
	end

	for i = 1, #class_parents do
		map(parent_keys:sub(i, i), function()
			pick(i)
		end)
	end
	map("<CR>", function()
		pick(vim.api.nvim_win_get_cursor(win)[1])
	end)
	map("q", close)
	map("<Esc>", close)
	-- leaving the float any other way closes it. Closing a window inside WinLeave isn't allowed, hence the schedule
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(close)
		end,
	})
end

-- a one-line float to type the class name in, under the parent's name. <CR> confirms; <Esc> leaves insert
-- mode like anywhere else, and <Esc> or q in normal mode cancels
local function input_name(parent, on_name)
	local title = " New " .. parent.name .. " subclass "
	local width = math.max(#title + 2, 32)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	-- mini.completion would pop up buffer words on every keystroke
	vim.b[buf].minicompletion_disable = true

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor(vim.o.lines / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = 1,
		style = "minimal",
		border = float_border(),
		title = title,
	})
	vim.cmd.startinsert()

	local function close()
		-- without it, closing from insert mode leaves the window underneath in insert mode
		vim.cmd.stopinsert()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	local function confirm()
		local name = vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
		close()
		-- write_class runs :edit, which waits until the insert-mode mapping has finished
		vim.schedule(function()
			on_name(name)
		end)
	end

	vim.keymap.set({ "i", "n" }, "<CR>", confirm, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(close)
		end,
	})
end

local function new_class()
	local oil_dir = require("oil").get_current_dir()
	if not oil_dir then
		vim.notify("UnrealNewClass: run it from an oil buffer", vim.log.levels.ERROR)
		return
	end
	local dir = vim.fs.normalize(oil_dir)
	local module = dir:match("/Source/([^/]+)")
	if not module then
		vim.notify("UnrealNewClass: " .. dir .. " isn't inside a Source module", vim.log.levels.ERROR)
		return
	end

	pick_parent(function(parent)
		input_name(parent, function(name)
			if name == "" then
				return
			end
			if not name:match("^[%a_][%w_]*$") then
				vim.notify("UnrealNewClass: " .. name .. " isn't a valid C++ name", vim.log.levels.ERROR)
				return
			end
			write_class(dir, module, parent, name)
		end)
	end)
end

vim.api.nvim_create_user_command("UnrealNewClass", new_class, {
	desc = "Create an Unreal class in the current oil directory",
})
vim.keymap.set("n", "<leader>y", new_class, { desc = "New Unreal class in the oil directory" })

-- status line: lualine calls status() about once a second. Editor detection runs from there,
-- at most every 3s and only inside an Unreal project, instead of on a timer of its own

local status_editors = {}
local status_checked = -math.huge
local status_checking = false
local success_visible_ms = 10000

local function refresh_status_editors()
	if status_checking or vim.uv.now() - status_checked < 3000 then
		return
	end
	status_checking = true
	find_running_editors(function(editors)
		status_checking = false
		status_checked = vim.uv.now()
		local before = status_editors[1] and status_editors[1].config
		status_editors = editors
		if (editors[1] and editors[1].config) ~= before then
			vim.api.nvim_exec_autocmds("User", { pattern = "UnrealEditorChanged", modeline = false })
		end
	end)
end

-- returns the text (already escaped for the status line) and the highlight group to color it with.
-- Priority: a running build, then a failed build (until the next one), then a running editor, then a recent success
local function status_state()
	if build then
		if build.total then
			local percent = math.floor(build.done / build.total * 100)
			return string.format("Building %s %d%%%%", build.config, percent), "DiagnosticWarn"
		end
		return "Building " .. build.config, "DiagnosticWarn"
	end
	if not find_unreal_root() then
		return "", nil
	end
	refresh_status_editors()

	local result = last_build_result
	if result and not result.ok then
		local count = result.errors > 0 and string.format(" (%d)", result.errors) or ""
		return result.config .. " build failed" .. count, "DiagnosticError"
	end
	if status_editors[1] then
		return status_editors[1].config .. " editor", "DiagnosticInfo"
	end
	if result and vim.uv.now() - result.finished < success_visible_ms then
		return result.config .. " build succeeded", "DiagnosticOk"
	end
	return "", nil
end

local function status()
	return (status_state())
end

-- lualine wants colors, not group names, from a color function
local function status_color()
	local _, group = status_state()
	local fg = group and vim.api.nvim_get_hl(0, { name = group, link = false }).fg
	return fg and { fg = string.format("#%06x", fg) } or {}
end

return {
	status = status,
	status_color = status_color,
}
