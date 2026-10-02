



local M = {}

-- #pragma region / endregion are two unrelated lines to Tree-sitter, so they can't fold through a query
-- This expression takes Tree-sitter's level and adds on for every region around the line
local region_start = "^%s*#%s*pragma%s+region"
local region_end = "^%s*#%s*pragma%s+endregion"


-- per buffer: { tick = changedtick, depth = { [lnum] = regions around that line } }
local cache = {}

local function region_depths(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local entry = cache[buf]
    if entry and entry.tick == tick then
        return entry.depth
    end

    local depth, open = {}, 0
    for lnum, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:match(region_start) then
            open = open + 1
            depth[lnum] = open
        elseif line:match(region_end) and open > 0 then
            depth[lnum] = open
            open = open - 1
        else
            depth[lnum] = open
        end
    end 
    cache[buf] = { tick = tick, depth = depth }
    return depth
end

function M.foldexpr()
    local lnum = vim.v.lnum
    local buf = vim.api.nvim_get_current_buf()
    local ts = tostring(vim.treesitter.foldexpr(lnum))
    local depth = region_depths(buf)[lnum] or 0
    if depth == 0 then
        return ts
    end

    local marker = ts:match("^[<>]") or ""
    local level = (tonumber(ts:match("%d+")) or 0) + depth
    local line = vim.fn.getline(lnum)
    if line:match(region_start) then
        return ">" .. level
    elseif line:match(region_end) then
        return "<" .. level
    end
    return marker .. level
end

-- clangd reports preprocessor branches that are compiled out (#if DS_DARKOS_ENABLED when it's 0) through
-- its textDocument/inactiveRegions extension. Each report replaces the last, so an empty list clears the dimming
local inactive_ns = vim.api.nvim_create_namespace("clangd_inactive_regions")

function M.on_inactive_regions(_, result)
    local buf = vim.uri_to_bufnr(result.textDocument.uri)
    if not vim.api.nvim_buf_is_loaded(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, inactive_ns, 0, -1)
    for _, region in ipairs(result.regions or {}) do
        vim.api.nvim_buf_set_extmark(buf, inactive_ns, region.start.line, 0, {
            end_row = region["end"].line + 1,
            end_col = 0,
            hl_group = "Comment",
            -- above Tree-sitter (100) and clangd's semantic tokens (125), so dead code doesn't keep its colors
            priority = 200,
            strict = false,
        })
    end
end

vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("cpp_regions", { clear = true }),
    callback = function(args)
        cache[args.buf] = nil
    end
})

-- a full-width background over every #pragma region ... #pragma endregion block, a shade stronger on the two
-- #pragma lines. Draw-time (ephemeral) marks can't carry line_hl_group, so these are stored marks, rebuilt
-- shortly after the buffer changes; between rebuilds they move with the text
local region_line_ns = vim.api.nvim_create_namespace("cpp_pragma_region_lines")

-- the shades are mixed from the colorscheme: CursorLine's background moved toward the text color, so a band never
-- matches the cursor line and follows whatever colorscheme is active
local function mix(from, to, amount)
    local function channel(color, shift)
        return math.floor(color / 2 ^ shift) % 256
    end
    local result = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
        local a, b = channel(from, shift), channel(to, shift)
        result = result + math.floor(a + (b - a) * amount + 0.5) * 2 ^ shift
    end
    return result
end

-- recomputed on every ColorScheme, and set outright (not default = true), so switching colorschemes mid-session
-- never leaves the previous scheme's shades behind
local function define_region_highlights()
    local dark = vim.o.background == "dark"
    local base = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg or (dark and 0x303030 or 0xe8e8e8)
    local text = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg or (dark and 0xd0d0d0 or 0x303030)
    vim.api.nvim_set_hl(0, "PragmaRegionBody", { bg = mix(base, text, 0.04) })
    vim.api.nvim_set_hl(0, "PragmaRegion", { bg = mix(base, text, 0.12) })
    -- the cursor line inside a region: clearly apart from both band shades
    vim.api.nvim_set_hl(0, "PragmaRegionCursor", { bg = mix(base, text, 0.24) })
end
define_region_highlights()

-- a band's full-line background covers CursorLine, so on a region line the cursor gets its own mark above the band
local region_cursor_ns = vim.api.nvim_create_namespace("cpp_pragma_region_cursor")

local function update_region_cursor(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, region_cursor_ns, 0, -1)
    if buf ~= vim.api.nvim_get_current_buf() or not vim.wo.cursorline then
        return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    if #vim.api.nvim_buf_get_extmarks(buf, region_line_ns, { row, 0 }, { row, 0 }, { limit = 1 }) > 0 then
        vim.api.nvim_buf_set_extmark(buf, region_cursor_ns, row, 0, {
            line_hl_group = "PragmaRegionCursor",
            priority = 100,
        })
    end
end

-- #if / #ifdef / #ifndef ... #endif get the same bands, with #else / #elif as edge lines like the #pragma ones
local preproc_if = "^%s*#%s*if"
local preproc_else = "^%s*#%s*el"
local preproc_endif = "^%s*#%s*endif"

-- #ifndef NAME followed by #define NAME is an include guard around the whole file; banding it would band everything
local function is_include_guard(lines, lnum)
    local name = lines[lnum]:match("^%s*#%s*ifndef%s+([%w_]+)")
    if not name then
        return false
    end
    for next_lnum = lnum + 1, #lines do
        local next_line = lines[next_lnum]
        if next_line:match("%S") then
            return next_line:match("^%s*#%s*define%s+" .. name .. "%f[^%w_]") ~= nil
        end
    end
    return false
end

local function update_region_bands(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, region_line_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- regions and #if blocks are matched on separate stacks, so one can't close the other
    local regions, conditionals = {}, {}
    local function band(first, last, edges)
        local depth = #regions + #conditionals
        for row = first - 1, last - 1 do
            local edge = row == first - 1 or row == last - 1 or edges[row + 1]
            vim.api.nvim_buf_set_extmark(buf, region_line_ns, row, 0, {
                line_hl_group = edge and "PragmaRegion" or "PragmaRegionBody",
                -- a nested block's lines sit above the outer one's
                priority = 10 + depth,
            })
        end
    end

    for lnum, line in ipairs(lines) do
        if line:match(region_start) then
            table.insert(regions, lnum)
        elseif line:match(region_end) and #regions > 0 then
            band(table.remove(regions), lnum, {})
        elseif line:match(preproc_if) then
            table.insert(conditionals, { first = lnum, guard = is_include_guard(lines, lnum), edges = {} })
        elseif line:match(preproc_else) and #conditionals > 0 then
            conditionals[#conditionals].edges[lnum] = true
        elseif line:match(preproc_endif) and #conditionals > 0 then
            local block = table.remove(conditionals)
            if not block.guard then
                band(block.first, lnum, block.edges)
            end
        end
    end
end

-- rebuilding on every keystroke would be wasted work while typing, so wait until the edits pause
local pending = {}

local function schedule_region_bands(buf)
    if pending[buf] then
        pending[buf]:stop()
    else
        pending[buf] = vim.uv.new_timer()
    end
    pending[buf]:start(150, 0, vim.schedule_wrap(function()
        if pending[buf] then
            pending[buf]:close()
            pending[buf] = nil
        end
        update_region_bands(buf)
        update_region_cursor(buf)
    end))
end

local band_group = vim.api.nvim_create_augroup("cpp_pragma_region_bands", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", { group = band_group, callback = define_region_highlights })
local function bands_for(buf)
    local filetype = vim.bo[buf].filetype
    if filetype == "cpp" or filetype == "c" then
        schedule_region_bands(buf)
    end
end

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter" }, {
    group = band_group,
    callback = function(args)
        local filetype = vim.bo[args.buf].filetype
        if filetype == "cpp" or filetype == "c" then
            update_region_cursor(args.buf)
        end
    end,
})
-- the window losing focus shouldn't keep a cursor line inside a region
vim.api.nvim_create_autocmd("WinLeave", {
    group = band_group,
    callback = function(args)
        if vim.api.nvim_buf_is_valid(args.buf) then
            vim.api.nvim_buf_clear_namespace(args.buf, region_cursor_ns, 0, -1)
        end
    end,
})

vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = band_group,
    callback = function(args)
        bands_for(args.buf)
    end,
})

-- the module first loads while a C++ buffer works out its folds, after that buffer's BufEnter has passed
bands_for(vim.api.nvim_get_current_buf())

return M
