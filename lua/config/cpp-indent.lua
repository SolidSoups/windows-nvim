-- tree-sitter doesn't know Unreal's macros. GENERATED_BODY(), UPROPERTY(...) and UFUNCTION(...) end without a ;, so
-- it parses each as a statement still waiting for one, and nvim-treesitter's indent puts the line below one level too
-- deep, or a closing }; one level too deep. Below a line that is nothing but an all-caps macro call, line up with the
-- macro instead: one level shallower for a closing } or an access specifier like public:
local M = {}

local access_specifiers = { public = true, protected = true, private = true }

local function lone_macro(line)
	return line:match("^%s*[%u_][%u%d_]*%b()%s*$") ~= nil
end

function M.indentexpr()
	local lnum = vim.v.lnum
	local prev = vim.fn.prevnonblank(lnum - 1)
	if prev == 0 or not lone_macro(vim.fn.getline(prev)) then
		return require("nvim-treesitter").indentexpr()
	end

	local base = vim.fn.indent(prev)
	local line = vim.fn.getline(lnum)
	if line:match("^%s*}") or access_specifiers[line:match("^%s*(%l+)%s*:") or ""] then
		base = base - vim.fn.shiftwidth()
	end
	return math.max(base, 0)
end

return M
