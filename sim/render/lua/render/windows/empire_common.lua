-- render/windows/empire_common.lua : what the empire and government views (render.views) share:
-- a builder that lays windows out one after the other (render.gui), the game's number formats,
-- the save's names, the game's definitions (common/...) and their icons.
--
--   local C = require("render.windows.empire_common")
--   local b = C.builder(ctx)                 -- ctx from render.views.build
--   local r = b:add(file, window, opts)      -- opts as render.gui's; r.rects: the rectangles
--   return b.items, b.report

local gui = require("render.gui")

local C = {}

local Builder = {}
Builder.__index = Builder

function C.builder(ctx)
    return setmetatable({
        ctx = ctx,
        items = {},
        report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} },
    }, Builder)
end

-- a window laid out with ctx's texture sizes and localisation; its report (rects) returned
function Builder:add(file, window, opts)
    opts = opts or {}
    opts.texture_size = opts.texture_size or self.ctx.texture_size
    opts.loc = opts.loc or self.ctx.loc
    local ok, items, report = pcall(gui.layout, self.ctx.game_dir, self.ctx.db, file, window, self.ctx.screen, opts)
    if not ok then
        self.report.missing_sprites[#self.report.missing_sprites + 1] = window .. ": " .. tostring(items)
        return { rects = {} }
    end
    gui.merge(self.items, self.report, items, report)
    return report
end

-- a window laid out with its run-time values given by element name (opts.named = { text = {},
-- frames = {}, sprites = {}, textures = {}, actions = {}, tints = {} }, name -> value) wherever
-- the element is in the window: a template whose elements sit at different depths in its
-- variants (the paragon cards)
function Builder:add_named(file, window, opts)
    local named = opts.named or {}
    opts.named = nil
    local probe = {}
    for k, v in pairs(opts) do
        probe[k] = v
    end
    probe.texture_size = self.ctx.texture_size
    probe.loc = nil
    local ok, _, report = pcall(gui.layout, self.ctx.game_dir, self.ctx.db, file, window, self.ctx.screen, probe)
    if ok then
        for path in pairs(report.rects) do
            local name = path:match("([^/]+)$")
            for kind, values in pairs(named) do
                local v = values[name]
                if v ~= nil then
                    opts[kind] = opts[kind] or {}
                    if opts[kind][path] == nil then
                        opts[kind][path] = v
                    end
                end
            end
        end
    end
    return self:add(file, window, opts)
end

-- What a country is, for the triggers the views evaluate (C.facts on the world's side):
-- { techs, traditions, ethics, civics, origin, authority, government, gestalt, hive, machine,
--   nomadic, comms }
function C.facts(w, c)
    local f = { techs = {}, traditions = {}, ethics = {}, civics = {} }
    local ts = w.field(c, "tech_status")
    for _, e in ipairs(type(ts) == "table" and ts or {}) do
        if e.op and e.key and e.key.text == "technology" and e.value.text then
            f.techs[(e.value.text:gsub('"', ""))] = true
        end
    end
    for _, t in ipairs(C.strings(w.field(c, "traditions"))) do
        f.traditions[t] = true
    end
    for _, t in ipairs(C.strings(w.path(c, "ethos", "ethics"))) do
        f.ethics[t] = true
    end
    local gov = w.field(c, "government")
    for _, t in ipairs(C.strings(w.field(gov, "civics"))) do
        f.civics[t] = true
    end
    f.origin = C.strip(w.field(gov, "origin"))
    f.authority = C.strip(w.field(gov, "authority"))
    f.government = C.strip(w.field(gov, "type"))
    f.hive = f.authority == "auth_hive_mind"
    f.machine = f.authority == "auth_machine_intelligence"
    f.gestalt = f.ethics.ethic_gestalt_consciousness or f.hive or f.machine or false
    f.country_type = C.strip(w.field(c, "type")) or "default"
    f.nomadic = f.country_type:find("nomad") ~= nil
    -- the DLCs the save names (meta.required_dlcs)
    f.dlcs = {}
    for _, n in ipairs(C.strings(w.meta.required_dlcs)) do
        f.dlcs[n] = true
    end
    -- communications with another empire: a relation with `communications = yes`
    f.comms = false
    for _, e in ipairs(w.field(c, "relations_manager") or {}) do
        if e.op and e.key and e.key.text == "relation" and type(e.value) == "table" and w.field(e.value, "communications") == "yes" then
            f.comms = true
        end
    end
    return f
end

-- the DLC triggers and the names the save's required_dlcs gives the DLCs [I: from the triggers'
-- documentation and the save]
C.DLCS = {
    has_paragon_dlc = "Galactic Paragons", has_overlord_dlc = "Overlord", has_federations_dlc = "Federations",
    has_megacorp = "Megacorp", has_nemesis = "Nemesis", has_apocalypse = "Apocalypse",
    has_ancrel = "Ancient Relics Story Pack", has_lithoids = "Lithoids Species Pack",
    has_machine_age_dlc = "The Machine Age", has_shroud_dlc = "Cosmic Storms",
    has_grand_archive_dlc = "Grand Archive", has_biogenesis_dlc = "BioGenesis",
}

-- a country trigger block evaluated on facts (the forms the views' potentials use; an unknown
-- trigger is false) [I: the game's script layer evaluates them]
-- Three-valued: an unknown trigger is unknown through AND, OR and NOT (AND false when one is
-- false, OR true when one is true); an unknown result is false, or true when `lenient`.
function C.trigger(block, f, lenient)
    local function yes(v)
        return v == "yes"
    end
    local test
    local function each(b, fn)
        for _, e in ipairs(type(b) == "table" and b or {}) do
            if e.op and e.key then
                fn(test(e.key.text, e.value.text and e.value.text:gsub('"', "") or e.value))
            end
        end
    end
    local function all(b)
        local r = true
        each(b, function(x)
            if x == false then
                r = false
            elseif x == nil and r == true then
                r = nil
            end
        end)
        return r
    end
    local function any(b)
        local r = false
        each(b, function(x)
            if x == true then
                r = true
            elseif x == nil and r == false then
                r = nil
            end
        end)
        return r
    end
    local function negate(x)
        if x == nil then
            return nil
        end
        return not x
    end
    local ETHIC = { "spiritualist", "materialist", "xenophile", "xenophobe", "egalitarian", "authoritarian", "militarist", "pacifist" }
    test = function(k, v)
        if k == "AND" then
            return all(v)
        elseif k == "OR" then
            return any(v)
        elseif k == "NOT" or k == "NOR" then
            return negate(any(v))
        elseif k == "NAND" then
            return negate(all(v))
        elseif k == "always" then
            return yes(v)
        elseif k == "is_nomadic" then
            return f.nomadic == yes(v)
        elseif k == "is_gestalt" then
            return (f.gestalt and true or false) == yes(v)
        elseif k == "is_hive_empire" then
            return f.hive == yes(v)
        elseif k == "is_machine_empire" then
            return f.machine == yes(v)
        elseif k == "is_wilderness_empire" then
            return false == yes(v)
        elseif k == "country_uses_consumer_goods" then
            return (not f.gestalt) == yes(v)
        elseif k == "has_comms_with_alien_empire" then
            return f.comms == yes(v)
        elseif k == "is_country_type" then
            return f.country_type == v
        elseif k == "has_menace_perk" or k == "has_ascension_perk" then
            -- (no perks read [I])
            return false
        elseif k == "has_origin" then
            return f.origin == v
        elseif k == "has_valid_civic" or k == "has_civic" then
            return f.civics[v] == true
        elseif k == "has_authority" then
            return f.authority == v
        elseif k == "has_government" then
            return f.government == v
        elseif k == "has_ethic" then
            return f.ethics[v] == true
        elseif k == "has_technology" then
            return f.techs[v] == true
        elseif k == "has_tradition" or k == "has_active_tradition" then
            return f.traditions[v] == true
        elseif k:match("^has_.+_dlc$") and C.DLCS[k] then
            return ((f.dlcs or {})[C.DLCS[k]] or false) == yes(v)
        end
        for _, e in ipairs(ETHIC) do
            if k == "is_" .. e then
                return (f.ethics["ethic_" .. e] or f.ethics["ethic_fanatic_" .. e] or false) == yes(v)
            elseif k == "is_fanatic_" .. e then
                return (f.ethics["ethic_fanatic_" .. e] or false) == yes(v)
            end
        end
        return nil
    end
    local r = all(block)
    if r == nil then
        return lenient and true or false
    end
    return r
end

-- the rectangle of an element of a window laid out alone (where its list is, for the wheel)
function C.rect_of(ctx, file, window, path)
    local ok, _, report = pcall(gui.layout, ctx.game_dir, ctx.db, file, window, ctx.screen, { texture_size = ctx.texture_size })
    return ok and report.rects[path] or nil
end

-- the wheel over a list (views.rs: a module's wheel): its first row shown one up or down, within
-- 0..max, kept in the state's `key`; nil when (x, y) is not over the list (the map's wheel)
function C.list_wheel(rect, state, key, notches, x, y, max)
    if not rect or x < rect.x or x > rect.x + rect.w or y < rect.y or y > rect.y + rect.h then
        return nil
    end
    local n = (tonumber(state[key]) or 0) + (notches > 0 and -1 or 1)
    n = math.max(0, math.min(max or n, n))
    return { [key] = tostring(n) }
end

-- a set from a list of names
function C.set(list)
    local s = {}
    for _, n in ipairs(list or {}) do
        s[n] = true
    end
    return s
end

-- a number as the game's GUI shows a large one (the top bar's: 5342 "5.3K"; cut, not rounded)
function C.short(v)
    return require("render.topbar").format(v)
end

-- an income with its sign ("+20", "-27"), whole units below 1000
function C.signed(v)
    v = tonumber(v) or 0
    local s = C.short(math.abs(v))
    return (v < 0 and "-" or "+") .. s
end

-- a localisation key's text (the key itself if there is none)
function C.loc(ctx, key)
    if ctx.loc and key and ctx.loc.has(key) then
        return (ctx.loc.get(key))
    end
    return key or ""
end

-- a localisation key's text as written, its $VARIABLES$ left for the caller to fill
function C.raw(ctx, key)
    if ctx.loc and key and ctx.loc.has(key) then
        return (ctx.loc.raw(key))
    end
    return key or ""
end

-- a save's name block (render.galaxy.name_block's table) as the game shows it
function C.name(ctx, n)
    if type(n) ~= "table" then
        return ""
    end
    return require("render.names").format(ctx.loc, n)
end

-- the definitions of a directory of common/ (name -> block), parsed once; their files'
-- scripted variables (`@x = 10`) by definition name in C.vars_cache[dir]
local defs_cache = {}
C.vars_cache = {}

-- a definition's number field, through its file's scripted variables
function C.number(ctx, dir, name, v)
    if type(v) == "string" and v:sub(1, 1) == "@" then
        C.defs(ctx, dir)
        local vars = (C.vars_cache[dir] or {})[name] or {}
        v = vars[v]
    end
    return tonumber(v)
end
function C.defs(ctx, dir)
    local d = defs_cache[dir]
    if not d then
        local source = require("stellar.script.source")
        d = {}
        local vars_of = {}
        for _, f in ipairs(source.files(ctx.game_dir, dir, "txt") or {}) do
            local tree = source.parse(ctx.game_dir, f)
            local vars = {}
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                    vars[e.key.text] = e.value.text
                elseif e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    d[e.key.text] = e.value
                    vars_of[e.key.text] = vars
                end
            end
        end
        defs_cache[dir] = d
        C.vars_cache[dir] = vars_of
    end
    return d
end

-- a definition's field: a token's text (unquoted), or its block
function C.field(block, key)
    local v = C.raw_field(block, key)
    if type(v) == "string" then
        return (v:gsub('"', ""))
    end
    return v
end

function C.raw_field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a save's token unquoted
function C.strip(v)
    if type(v) == "table" and v.text then
        v = v.text
    end
    return type(v) == "string" and (v:gsub('"', "")) or v
end

-- the tokens of a block (a list of strings), unquoted
function C.strings(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = (e.text:gsub('"', ""))
        end
    end
    return out
end

-- the names of a directory's definitions in load order (files by name, then file order)
local order_cache = {}
function C.def_order(ctx, dir)
    local o = order_cache[dir]
    if not o then
        local source = require("stellar.script.source")
        o = {}
        for _, f in ipairs(source.files(ctx.game_dir, dir, "txt") or {}) do
            for _, e in ipairs(source.parse(ctx.game_dir, f) or {}) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    o[#o + 1] = e.key.text
                end
            end
        end
        order_cache[dir] = o
    end
    return o
end

-- a define (common/defines: `NGroup = { KEY = value }`)
function C.define(ctx, group, key)
    local g = C.defs(ctx, "common/defines")[group]
    return g and C.field(g, key)
end

-- a named colour (common/named_colors: `name = { color = { r g b a } }`, 0..255) as 0..1
function C.named_colour(ctx, name)
    local b = name and C.defs(ctx, "common/named_colors")[name]
    local c = b and C.raw_field(b, "color")
    if type(c) ~= "table" then
        return nil
    end
    local n = {}
    for _, e in ipairs(c) do
        if e.text and tonumber(e.text) then
            n[#n + 1] = tonumber(e.text)
        end
    end
    if #n < 3 then
        return nil
    end
    local k = (n[1] > 1 or n[2] > 1 or n[3] > 1 or (n[4] or 0) > 1) and 255 or 1
    return { n[1] / k, n[2] / k, n[3] / k, (n[4] or k) / k }
end

-- entries in an overlapping elements box (OverlappingElementsBoxType): side by side `spacing`
-- apart from its left, closer together when they would not fit (each then overlaps the one
-- before) [I: the spacing rule]; fn(i, x, y, prefix) lays the i-th out
function C.overlap(b, rect, n, entry_w, spacing, fn)
    if n <= 0 then
        return
    end
    local step = entry_w + spacing
    if n > 1 and (n - 1) * step + entry_w > rect.w then
        step = (rect.w - entry_w) / (n - 1)
    end
    for i = 1, n do
        fn(i, rect.x + (i - 1) * step, rect.y, "/entries" .. tostring(rect.x) .. "_" .. tostring(rect.y) .. "/" .. i)
    end
end

-- a sprite (a frame of it) drawn at a place the code gives (an icon's layer)
function Builder:sprite(path, name, x, y, w, h, tint, frame)
    local s = self.ctx.db.sprites[name]
    if s and s.sheet and self.ctx.db.sprites[s.sheet] then
        frame = frame or s.default_frame
        name = s.sheet
        s = self.ctx.db.sprites[name]
    end
    if not (s and s.texture) then
        self.report.missing_sprites[#self.report.missing_sprites + 1] = tostring(name)
        return
    end
    self.items[#self.items + 1] = {
        kind = "sprite", path = path, sprite = name, texture = s.texture, sprite_kind = s.kind,
        frame = frame or 1, frames = s.frames or 1, x = x, y = y, w = w, h = h, tint = tint,
    }
    self.report.sprites = self.report.sprites + 1
end

-- a texture file drawn at a place
function Builder:texture(path, file, x, y, w, h, tint)
    self.items[#self.items + 1] = {
        kind = "sprite", path = path, sprite = file, texture = file, sprite_kind = "spriteType",
        frame = 1, frames = 1, x = x, y = y, w = w, h = h, tint = tint,
    }
    self.report.sprites = self.report.sprites + 1
end

-- the icon file of a definition with `icon = "gfx/..."` (civics, origins, traits ...); or the
-- convention's file when it has none
function C.icon_file(ctx, dir, key, fallback)
    local b = C.defs(ctx, dir)[key]
    local icon = b and C.field(b, "icon")
    if type(icon) == "string" then
        icon = icon:gsub('"', "")
        if icon:find("/", 1, true) then
            return icon
        end
    end
    return fallback
end

return C
