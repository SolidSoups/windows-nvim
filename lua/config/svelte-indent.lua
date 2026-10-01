-- nvim-treesitter's indent returns 0 in two common Svelte spots: the first
-- line inside <script>/<style>, and anywhere after a tag that isn't closed yet
-- (every line of a component you're still typing). When it returns 0, fall
-- back to the previous line's indent: one level deeper if that line opens a
-- block, one level shallower if this line closes one.
local M = {}

local void_tags = {
	area = true,
	base = true,
	br = true,
	col = true,
	embed = true,
	hr = true,
	img = true,
	input = true,
	link = true,
	meta = true,
	source = true,
	track = true,
	wbr = true,
}

-- <tag ...> without its closing tag, {#if ...} or {:else}, or a trailing ( [ {
local function opens_block(line)
	-- blank out {expressions} so a > inside one doesn't end the tag early
	local markup = line:gsub("%b{}", "{}")
	local tag = markup:match("<([%w%-:%.]+)[^<>]*>$")
	if tag and not markup:match("/>$") and not void_tags[tag:lower()] and not markup:find("</" .. tag, 1, true) then
		return true
	end
	return line:match("^{[#:][^}]*}$") ~= nil or line:match("[{%[(]$") ~= nil
end

-- </tag>, {/if} or {:else}, or a leading } ] )
local function closes_block(line)
	return line:match("^</") ~= nil or line:match("^{[/:]") ~= nil or line:match("^[}%])]") ~= nil
end

function M.indentexpr()
	local lnum = vim.v.lnum

	-- treesitter indents </script> and </style> like the code inside them;
	-- line them up with their opening tag instead
	local closing = vim.fn.getline(lnum):match("^%s*</(%a+)")
	if closing == "script" or closing == "style" then
		for l = lnum - 1, 1, -1 do
			if vim.fn.getline(l):match("^%s*<" .. closing .. "[%s>]") then
				return vim.fn.indent(l)
			end
		end
	end

	local indent = require("nvim-treesitter").indentexpr()
	if indent ~= 0 or lnum == 1 then
		return indent
	end

	local prev = vim.fn.prevnonblank(lnum - 1)
	if prev == 0 then
		return 0
	end

	local base = vim.fn.indent(prev)
	if opens_block(vim.trim(vim.fn.getline(prev))) then
		base = base + vim.fn.shiftwidth()
	end
	if closes_block(vim.trim(vim.fn.getline(lnum))) then
		base = base - vim.fn.shiftwidth()
	end
	return math.max(base, 0)
end

return M
