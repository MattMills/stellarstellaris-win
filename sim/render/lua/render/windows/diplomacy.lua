-- render/windows/diplomacy.lua : the diplomacy windows laid out from the game's GUI files
-- (docs/windows/diplomacy.md): Contacts (interface/galaxy_view.gui, CGalaxyView), a country's
-- diplomacy (diplomacy_view.gui, CDiplomacyView), the galactic community, a federation, a war.
-- The world's part comes from render.windows.diplomacy_data (a chunk the galaxy carries).
--
--   local items, report, flags = require("render.windows.diplomacy").build(game_dir, db, screen,
--       texture_size, loc, state, chunk)
--   state = { window = "contacts"|"country"|"community"|"federation"|"war", id, selected, tab,
--             sort, observe }
--   flags: element path -> country id (the flag sprites the renderer composes)

local gui = require("render.gui")
local names = require("render.names")
local diplomacy_data = require("render.windows.diplomacy_data")

local M = {}

local function new_report()
    return { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
end

local function set(list)
    local s = {}
    for _, n in ipairs(list or {}) do
        s[n] = true
    end
    return s
end

-- a context: the layout's common arguments and what it collects
local function context(game_dir, db, screen, texture_size, loc, data)
    local ctx = { game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc,
        data = data, items = {}, report = new_report(), flags = {} }
    -- ctx:layout(file, window, opts) lays a window out and keeps its items; the report's rects
    function ctx.layout(file, window, opts)
        opts = opts or {}
        opts.texture_size = texture_size
        opts.loc = loc
        local i, r = gui.layout(game_dir, db, file, window, screen, opts)
        gui.merge(ctx.items, ctx.report, i, r)
        return r
    end
    -- a name block localised
    function ctx.name(block)
        if not block then
            return ""
        end
        return names.format(loc, block)
    end
    -- ctx.fmt(key, vars) -> the key's text with its $NAME|format$ values filled in (the game's
    -- CGameText formats as far as these windows use them: digits are decimals, `*` an SI number
    -- (K, M), `+` a sign and green or red, a letter a colour code)
    function ctx.fmt(key, vars)
        local text = loc and loc.has(key) and loc.get(key) or key
        return M.fill(text, vars or {})
    end
    -- ctx.icons(path, rect, sprites, align): an OverlappingElementsBox filled with icons (each
    -- its sprite's size, side by side, overlapping when they do not fit), aligned left or right
    -- in the box's rectangle, vertically centred
    function ctx.icons(path, rect, sprites, align)
        local list, total = {}, 0
        for _, s in ipairs(sprites) do
            local d = db.sprites[s]
            local tw, th
            if d and d.texture then
                tw, th = texture_size(d.texture)
            end
            if tw and th then
                local w = tw / math.max(1, d.frames or 1)
                list[#list + 1] = { s = s, d = d, w = w, h = th }
                total = total + w
            end
        end
        if #list == 0 or not rect then
            return
        end
        local step = (#list > 1 and total > rect.w) and (rect.w - list[#list].w) / (#list - 1) or nil
        local width = step and rect.w or total
        local x = align == "right" and rect.x + rect.w - width or rect.x
        for i, it in ipairs(list) do
            ctx.items[#ctx.items + 1] = {
                kind = "sprite", path = path .. "/" .. i, sprite = it.s, texture = it.d.texture,
                sprite_kind = it.d.kind or "spriteType", frame = 1, frames = it.d.frames or 1,
                x = x, y = rect.y + (rect.h - it.h) / 2, w = it.w, h = it.h,
            }
            ctx.report.sprites = ctx.report.sprites + 1
            x = x + (step or it.w)
        end
    end
    -- ctx.texture(path) -> a sprite name for a texture the game names by its path (an icon the
    -- engine finds by name, as the authorities' gfx/interface/icons/governments/authorities/<key>.dds),
    -- added to the .gfx database once
    function ctx.texture(path)
        local name = "@texture:" .. path
        if not db.sprites[name] then
            db.sprites[name] = { name = name, texture = path, frames = 1, kind = "spriteType" }
        end
        return name
    end
    return ctx
end

M.context = context

-- a Lua chunk ("return { ... }") as its table, cached by the chunk (the windows lay out often)
local chunks = setmetatable({}, { __mode = "v" })
function M.load_chunk(chunk)
    local t = chunks[chunk]
    if not t then
        local f = (loadstring or load)(chunk, "=diplomacy chunk")
        t = f and f() or {}
        chunks[chunk] = t
    end
    return t
end

-- intel (common/intel_levels, common/intel_categories): the levels' ranges, their frame and each
-- category's level; an item (`authority`, `intel_economy_colonies_low`, ...) is known from its
-- category's level on, its least intel the first level's range's low end. M.intel_need(game_dir,
-- item) -> that intel; M.intel_frame(game_dir, intel) -> the level's `frame` (GFX_intel_level_N)
local intel_cache
local function intel_tables(game_dir)
    if not intel_cache then
        local source = require("stellar.script.source")
        local get = require("render.gfx").get
        local levels = {}
        for _, d in pairs(source.definitions(game_dir, "common/intel_levels") or {}) do
            local range = get(d.block, "intel")
            local lo, hi
            if type(range) == "table" then
                for _, e in ipairs(range) do
                    if e.text then
                        if lo == nil then lo = tonumber(e.text) else hi = tonumber(e.text) end
                    end
                end
            end
            local l = { lo = lo or 0, hi = hi or lo or 0, frame = tonumber(get(d.block, "frame")) or 1, cat = {} }
            for _, c in ipairs({ "government", "diplomacy", "economy", "technology", "military" }) do
                l.cat[c] = tonumber(get(d.block, c)) or 0
            end
            levels[#levels + 1] = l
        end
        table.sort(levels, function(a, b) return a.lo < b.lo end)
        -- the levels' five categories (the others, the pacts' and federations', grant their items
        -- with the pact)
        local items = {}
        local defs = source.definitions(game_dir, "common/intel_categories") or {}
        for _, name in ipairs({ "government", "diplomacy", "economy", "technology", "military" }) do
            local d = defs[name] or { block = {} }
            local k = 0
            for _, e in ipairs(d.block) do
                if e.op and e.key and e.key.text == "intel_level" and type(e.value) == "table" then
                    for _, v in ipairs(e.value) do
                        if v.text then
                            items[v.text] = { category = name, level = k }
                        end
                    end
                    k = k + 1
                end
            end
        end
        intel_cache = { levels = levels, items = items }
    end
    return intel_cache
end

function M.intel_need(game_dir, item)
    local t = intel_tables(game_dir)
    local it = t.items[item]
    if not it then
        return 101
    end
    for _, l in ipairs(t.levels) do
        if (l.cat[it.category] or 0) >= it.level then
            return l.lo
        end
    end
    return 101
end

function M.intel_frame(game_dir, intel)
    for _, l in ipairs(intel_tables(game_dir).levels) do
        if intel >= l.lo and intel <= l.hi then
            return l.frame
        end
    end
    return 1
end

-- the country types' flags the windows read (common/country_types, CCountryType::ReadMember: type
-- +0x48 bits): relations (7), custom_opinion (34), show_in_contacts_list (35),
-- minimalist_contacts_list_profile (36); read once
local country_types_cache
function M.country_types(game_dir)
    if not country_types_cache then
        local source = require("stellar.script.source")
        local get = require("render.gfx").get
        country_types_cache = {}
        local defs = source.definitions(game_dir, "common/country_types") or {}
        for name, d in pairs(defs) do
            local function yes(k)
                return get(d.block, k) == "yes"
            end
            country_types_cache[name] = {
                relations = yes("relations"), custom_opinion = yes("custom_opinion"),
                -- (show_in_contacts_list: yes by default, as the file's header says)
                show_in_contacts_list = get(d.block, "show_in_contacts_list") ~= "no",
                minimalist = yes("minimalist_contacts_list_profile"),
            }
        end
    end
    return country_types_cache
end

-- an SI number as the game's CreateSIValue: whole under 1000, then K and M with one decimal
-- (cut, not rounded)
function M.si(v)
    local a = math.abs(v)
    local function cut(x)
        return math.floor(x * 10) / 10
    end
    if a >= 1e6 then
        return string.format("%.1fM", (v < 0 and -1 or 1) * cut(a / 1e6))
    elseif a >= 1e3 then
        return string.format("%.1fK", (v < 0 and -1 or 1) * cut(a / 1e3))
    end
    return tostring(math.floor(v + (v >= 0 and 0 or 0)))
end

-- a value through a $NAME|format$ format
function M.format_value(v, f)
    local colour
    if type(v) == "number" then
        local digits = tonumber(f:match("(%d)"))
        local s
        if f:find("*", 1, true) then
            s = M.si(v)
        elseif digits then
            s = string.format("%." .. digits .. "f", v)
        else
            s = (v == math.floor(v)) and string.format("%d", v) or string.format("%.2f", v)
        end
        if f:find("+", 1, true) then
            if v > 0 then
                s, colour = "+" .. s, "G"
            elseif v < 0 then
                colour = "R"
            else
                colour = "Y"
            end
        end
        v = s
    end
    colour = f:match("([A-Z])") or colour
    if colour then
        return "§" .. colour .. tostring(v) .. "§!"
    end
    return tostring(v)
end

function M.fill(text, vars)
    return (text:gsub("%$([%w_]+)|?([^%$]*)%$", function(name, f)
        local v = vars[name]
        if v == nil then
            return nil
        end
        return M.format_value(v, f or "")
    end))
end

local WINDOWS = {}

-- the window's lua module (one per window family): contacts, country, ...
local function module_of(window)
    local m = WINDOWS[window]
    if m == nil then
        local ok, mod = pcall(require, "render.windows.diplomacy_" .. window)
        m = ok and mod or false
        if not ok then
            M.last_error = mod
        end
        WINDOWS[window] = m
    end
    return m or nil
end

function M.build(game_dir, db, screen, texture_size, loc, state, chunk)
    local data = diplomacy_data.load(chunk) or { countries = {}, order = {}, relations = {}, their = {},
        opinion = {}, attitude = {}, intel = {}, federations = {}, wars = {}, player = -1 }
    local ctx = context(game_dir, db, screen, texture_size, loc, data)
    ctx.state = state
    local m = module_of(state.window)
    if m then
        local ok, err = pcall(m.build, ctx, state)
        if not ok then
            ctx.report.missing_sprites[#ctx.report.missing_sprites + 1] = "diplomacy " .. state.window .. ": " .. tostring(err)
            io.stderr:write("render.windows.diplomacy: " .. tostring(err) .. "\n")
        end
    else
        io.stderr:write("render.windows.diplomacy: no window " .. tostring(state.window) .. " (" .. tostring(M.last_error) .. ")\n")
    end
    return ctx.items, ctx.report, ctx.flags
end

M.set = set

return M
