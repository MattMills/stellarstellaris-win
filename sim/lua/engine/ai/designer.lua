-- engine/ai/designer.lua : the AI's ship designer (docs/ai_fleets.md section 4), what
-- CAIInteriorMinister::RequestNewShipDesign (Linux 4.5.2 0x2765d20) makes of a ship size and a
-- role, and the command that adds the design to the country (CCreateOrUpdateShipDesignCommand).
--
--   RequestNewShipDesign(info, owner):
--     r1 = AI draw; CCountry::CreateShipDesign(size, class, owner, r1, cap) (0x233f4a0): a design
--       of the size's growth stages named "Temp <size>", sections from CCrudeRandom(r1)
--       (AddRandomSectionsToShipDesign, role ""), its required and section components
--     r2 = AI draw; role = SShipDesignPreferences::GetEffectiveRoleForShipSize(size, personality,
--       r2) (0x26cac00: the country's ai_ship_role_overrides of the size, r % their total weight,
--       else the personality's)
--     with a role: the design's role set, its sections cleared, AddRandomSectionsToShipDesign(0)
--       (so the sections are rolled with seed 0), AddRandomSectionsToShipDesign(r3 = AI draw) (a
--       no-op: every slot is filled), AddRequiredComponentsToShipDesign, r4 = AI draw,
--       AddSectionComponentsToShipDesign(r4)
--     the country's design of the info's name and size with identical components, else any of its
--       designs of the size with identical components (newest first: its name then becomes the
--       info's), is returned (and the info dated today); else the design is named, posted as a
--       CCreateOrUpdateShipDesignCommand and nil is returned (the AI orders it a day later)
--
--   the section of a slot (CShipDesignTemplatesDatabase::FindRandomSectionTemplate 0x2b091d0): the
--     section templates in the database's order that fit the size and slot, whose prerequisites
--     the country has, with the role in their ai_tags (any, without a role); each with ai_weight
--     w > 0 rolls (crude % w); the highest roll wins (the first on a tie), among the sections whose
--     weapon slots can all be filled when there is one (SectionWeaponSlotsFillable [I: every
--     weapon slot has a candidate]); else the first fitting one; none with the role: again
--     without it
--   weapons (AddWeaponsToShipDesignSection 0x23757a0, FindBestWeaponTemplate 0x2b097a0): per
--     weapon slot, every weapon the country can build (prerequisites, potential) of the slot's
--     size with ai_weight > 0 scores (10 - power) x DESIGNER_WEAPON_PREF_MUL (its tags hold the
--     preferred weapon type; DESIGNER_STARBASE_WEAPON_PREF_MUL for stations) x
--     DESIGNER_WEAPON_ROLE_MUL (its ai_tags hold the role) / (1 + DESIGNER_WEAPON_STACKING_DIV x
--     the components placed sharing one of its tags [I: one each]) x ai_weight; the best (a tie:
--     the newer one when (country id ^ index) is even)
--   utilities (AddUtilities 0x23743a0, FindBestUtility 0x2b0b330, FindBestAuxUtility): per
--     utility slot, armor or shields, the one further below the country's ratio (armor first on
--     a tie) [I: matches the game's designs of 180 days], the best of that kind by ai_weight
--     (x DESIGNER_UTILITY_ROLE_MUL for the role); aux slots the best aux utility
--   required components (AddRequiredComponentsToShipDesign 0x2340050,
--     CComponentSet::FindBestRequiredComponent 0x22f3a60): per required_component_set of the
--     size, the set's buildable component with the highest ai_weight (x DESIGNER_UTILITY_ROLE_MUL
--     with the role in its ai_tags), the first on a tie
--
-- Not modelled: the cost restriction (a cheaper design asked for), strike craft and mutation
-- slots, RemoveNonPoweredComponentsInShipDesign (no tier 1 design runs short of power),
-- UpgradeComponents (the components chosen are the best already), the size families, the
-- federation's and galactic community's designs, the design's name list draw
-- (TakeRandomShipClassNameForDesign: a deterministic pick from the draw [I]).

local world = require("engine.world")
local defs = require("engine.defs")
local slice = require("engine.slice")

local designer = { stats = { generated = 0, reused = 0, posted = 0, created = 0, no_section = 0, errors = 0 } }
local S = designer.stats

local function unq(v)
    if v == nil then return nil end
    return (tostring(v):gsub('^"(.*)"$', "%1"))
end

local function create()
    return require("engine.fleets.create")
end

local function num(v, file)
    if v == nil then return nil end
    return create().number(v, file)
end

-- ---------------------------------------------------------------------------------------------
-- CCrudeRandom (Linux 0x422b070): a CNoiseRandom { position, seed = 0 } whose position is the
-- noise of (value, 0x5ea6ba9f); GetInteger is CNoiseRandom::GetInteger ((h & 0x7ffffffe) ^ h >> 8)

local CRUDE_SEED = 0x5ea6ba9f
local function u32(x)
    return x % 4294967296
end
local function next_raw(pos, seed)
    local h = RUST.noise_raw(u32(pos), u32(seed))
    return h
end
local function getnext(pos, seed)
    local h = next_raw(pos, seed)
    return bit.bxor(h, bit.rshift(h, 8)) % 4294967296
end

local crude_mt = {}
crude_mt.__index = crude_mt
function crude_mt:int()
    local h = next_raw(self.pos, self.seed)
    self.pos = u32(self.pos + 1)
    local v = bit.bxor(bit.band(h, 0x7ffffffe), bit.rshift(h, 8))
    return v % 4294967296
end
local function crude(value)
    return setmetatable({ pos = getnext(u32(value), CRUDE_SEED), seed = 0 }, crude_mt)
end
designer.crude = crude

-- ---------------------------------------------------------------------------------------------
-- the databases in load order

local ordered_cache = {}
local function ordered(folder)
    local l = ordered_cache[folder]
    if l then
        return l
    end
    l = { list = {}, by = {} }
    local db = require("simscript.db")
    local source = require("stellar.script.source")
    for _, file in ipairs(source.files(db.fs, folder, "txt")) do
        for _, e in ipairs(source.parse(db.fs, file) or {}) do
            if e.op and e.key and e.value.text == nil then
                local key = unq(defs.field(e.value, "key"))
                if key and not l.by[key] then
                    local t = { key = key, kind = e.key.text, block = e.value, file = file }
                    l.list[#l.list + 1] = t
                    l.by[key] = t
                end
            end
        end
    end
    ordered_cache[folder] = l
    return l
end
local function components() return ordered("common/component_templates") end
local function sections() return ordered("common/section_templates") end
designer.components, designer.sections = components, sections

local function list_of(block, key)
    local out = {}
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            if e.value.text then
                out[#out + 1] = unq(e.value.text)
            else
                for _, x in ipairs(e.value) do
                    if x.text then out[#out + 1] = unq(x.text) end
                end
            end
        end
    end
    return out
end
local function set_of(block, key)
    local s = {}
    for _, v in ipairs(list_of(block, key)) do s[v] = true end
    return s
end

-- the information of a component template, once
local cinfo_cache = setmetatable({}, { __mode = "k" })
local function cinfo(c)
    local i = cinfo_cache[c]
    if i then return i end
    local b = c.block
    local mods = defs.field(b, "modifier")
    i = {
        size = unq(defs.field(b, "size")), set = unq(defs.field(b, "component_set")),
        power = num(defs.field(b, "power"), c.file) or 0,
        tags = set_of(b, "tags"), ai_tags = set_of(b, "ai_tags"), prereq = list_of(b, "prerequisites"),
        armor = type(mods) == "table" and (num(defs.field(mods, "ship_armor_add"), c.file) or 0) > 0,
        shield = type(mods) == "table" and (num(defs.field(mods, "ship_shield_add"), c.file) or 0) > 0,
        hull = type(mods) == "table" and (num(defs.field(mods, "ship_hull_add"), c.file) or 0) > 0,
        weapon = c.kind == "weapon_component_template", utility = c.kind == "utility_component_template",
        strike = c.kind == "strike_craft_component_template",
    }
    cinfo_cache[c] = i
    return i
end

-- ---------------------------------------------------------------------------------------------
-- triggers in the design's scope: is_ship_size / is_ship_class / the ship scripted triggers on
-- the design, `from` and the country's own triggers through the script layer

local function country_trigger(block, ctx)
    local ok, v = pcall(require("simscript.eval").trigger, block, ctx)
    return ok and v and true or false
end

local SHIP_KEYS = { is_ship_size = true, is_ship_class = true, is_arkship_ship = true, is_cloaked = true,
    exists = true, has_armor_percentage = true, is_eager_explorer_ship = true, is_waystation_ship = true,
    has_non_psionic_shields = true, has_component = true }

local design_trigger
local function eval_entry(e, d)
    local k = e.key.text
    local v = e.value.text and unq(e.value.text)
    if k == "AND" then return design_trigger(e.value, d, "and") end
    if k == "OR" then return design_trigger(e.value, d, "or") end
    if k == "NOT" or k == "NOR" then return not design_trigger(e.value, d, "or") end
    if k == "NAND" then return not design_trigger(e.value, d, "and") end
    if k == "from" or k == "owner" then return country_trigger(e.value, d.ctx) end
    if k == "is_ship_size" then return v == d.size end
    if k == "is_ship_class" then return v == d.class end
    if k == "is_arkship_ship" then return (v == "yes") == (d.size:find("arkship") ~= nil) end
    if SHIP_KEYS[k] then return v == "no" end
    -- a scripted trigger: the ship_* ones are evaluated on the design; others on the country
    local st = defs.get("common/scripted_triggers", k)
    if st and k:find("^ship_") then
        local r = design_trigger(st.block, d, "and")
        if v == "no" then return not r end
        return r
    end
    return country_trigger({ e }, d.ctx)
end
function design_trigger(block, d, mode)
    if type(block) ~= "table" then return true end
    for _, e in ipairs(block) do
        if e.op and e.key then
            local r = eval_entry(e, d)
            if mode == "or" and r then return true end
            if mode ~= "or" and not r then return false end
        end
    end
    return mode ~= "or"
end
designer.design_trigger = design_trigger

local expanded = setmetatable({}, { __mode = "k" })
local function expand(block, file)
    if type(block) ~= "table" then return block end
    local x = expanded[block]
    if x then return x end
    x = block
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text:lower() == "inline_script" then
            local db = require("simscript.db")
            x = require("stellar.script.source").expand(db.fs, block, {}, 0, "file: " .. tostring(file)) or block
            break
        end
    end
    expanded[block] = x
    return x
end

-- a weight block (ai_weight) in the design's scope: weight/base then modifiers (factor, add)
local function weight_of(block, file, d)
    if block == nil then
        return 1
    end
    if type(block) ~= "table" then
        return num(block, file) or 0
    end
    block = expand(block, file)
    local acc = 1
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text:lower()
            if k == "weight" or k == "base" or k == "factor" then
                acc = num(e.value.text, file) or acc
            elseif k == "modifier" and e.value.text == nil then
                local cond = {}
                for _, x in ipairs(e.value) do
                    if x.op and x.key and not ({ factor = true, add = true, weight = true })[x.key.text:lower()] then
                        cond[#cond + 1] = x
                    end
                end
                if design_trigger(cond, d, "and") then
                    for _, x in ipairs(e.value) do
                        if x.op and x.key then
                            local xk = x.key.text:lower()
                            if xk == "factor" then acc = acc * (num(x.value.text, file) or 1)
                            elseif xk == "add" then acc = acc + (num(x.value.text, file) or 0) end
                        end
                    end
                end
            end
        end
    end
    return acc
end

-- ---------------------------------------------------------------------------------------------
-- the country's preferences (SShipDesignPreferences: the country's overrides, else its personality)

local function personality(country)
    local p = unq(world.field(world.object("country", country), "personality"))
    return p and defs.get("common/personalities", p)
end

function designer.preferences(country)
    local c = world.object("country", country)
    local pd = personality(country)
    local pb = pd and pd.block or {}
    local function pick(field, pfield)
        local v = world.field(c, field)
        if v ~= nil and type(v) ~= "table" then return unq(v) end
        return defs.field(pb, pfield)
    end
    return {
        weapon = pick("ai_weapon_preference_override", "weapon_preferences"),
        armor = tonumber(pick("ai_armor_ratio_override", "armor_ratio")) or 0,
        shields = tonumber(pick("ai_shields_ratio_override", "shields_ratio")) or 0,
    }
end

-- GetEffectiveRoleForShipSize(size, personality, r): the country's ai_ship_role_overrides of the
-- size (each `size = { role = weight }`), the first whose running weight exceeds r % the total;
-- else the personality's ship_roles; else no role ("")
function designer.role_for(country, size, r)
    local c = world.object("country", country)
    local list, total = {}, 0
    local ov = world.field(c, "ai_ship_role_overrides")
    for key, v in world.statements(type(ov) == "table" and ov or {}) do
        if key == size and type(v) == "table" then
            for role, w in world.statements(v) do
                local n = tonumber(w) or 0
                list[#list + 1] = { unq(role), n }
                total = total + n
            end
        end
    end
    if total <= 0 then
        list, total = {}, 0
        local pd = personality(country)
        local sr = pd and defs.field(pd.block, "ship_roles")
        for _, e in ipairs(type(sr) == "table" and sr or {}) do
            if e.op and e.key and unq(e.key.text) == size then
                list[#list + 1] = { unq(e.value.text), 1 }
                total = total + 1
            end
        end
    end
    if total <= 0 then
        return ""
    end
    local t, acc = r % total, 0
    for _, x in ipairs(list) do
        acc = acc + x[2]
        if t < acc then return x[1] end
    end
    return ""
end

-- ---------------------------------------------------------------------------------------------
-- the generation

local DEF
local function defines()
    if DEF then return DEF end
    DEF = { pref = 1.33, starbase_pref = 5.33, role = 5.33, util_role = 5.33, stacking = 0.05 }
    for _, d in pairs(defs.folder("common/defines")) do
        local g = defs.field(d.block, "NShip")
        if type(g) == "table" then
            DEF.pref = tonumber(defs.field(g, "DESIGNER_WEAPON_PREF_MUL")) or DEF.pref
            DEF.starbase_pref = tonumber(defs.field(g, "DESIGNER_STARBASE_WEAPON_PREF_MUL")) or DEF.starbase_pref
            DEF.role = tonumber(defs.field(g, "DESIGNER_WEAPON_ROLE_MUL")) or DEF.role
            DEF.util_role = tonumber(defs.field(g, "DESIGNER_UTILITY_ROLE_MUL")) or DEF.util_role
            DEF.stacking = tonumber(defs.field(g, "DESIGNER_WEAPON_STACKING_DIV")) or DEF.stacking
        end
    end
    return DEF
end

local function has_techs(country, list)
    local research = require("engine.research")
    for _, t in ipairs(list) do
        if research.level(country, t) == nil then return false end
    end
    return true
end

-- the component sets of space fauna (`is_space_fauna_component_set = yes`, the set's flag the
-- weapon pick tests: CComponentSet +0xa4) [I: for every kind of component]
local FAUNA
local function fauna_set(name)
    if FAUNA == nil then
        FAUNA = {}
        for _, s in ipairs(ordered("common/component_sets").list) do
            if defs.field(s.block, "is_space_fauna_component_set") == "yes" then
                FAUNA[s.key] = true
            end
        end
    end
    return name ~= nil and FAUNA[name] or false
end

-- CComponentTemplate::CanBeBuiltBy + IsAllowed: not hidden, not of a space fauna set, its
-- prerequisites, potential and possible
local function component_ok(c, d)
    local i = cinfo(c)
    if defs.field(c.block, "hidden") == "yes" or fauna_set(i.set) then return false end
    if not has_techs(d.country, i.prereq) then return false end
    for _, key in ipairs({ "potential", "possible" }) do
        local t = defs.field(c.block, key)
        if type(t) == "table" and not design_trigger(t, d, "and") then return false end
    end
    return true
end

-- a section template's slots in order: its component_slot entries (weapon, strike craft or utility
-- by the slot template's `component`), then its small / medium / large / aux utility slots
local SLOT_NAMES = { { "small_utility_slots", "SMALL_UTILITY_", "small" }, { "medium_utility_slots", "MEDIUM_UTILITY_", "medium" },
    { "large_utility_slots", "LARGE_UTILITY_", "large" }, { "aux_utility_slots", "AUX_UTILITY_", "aux" } }
local slots_cache = setmetatable({}, { __mode = "k" })
local function section_slots(sec)
    local s = slots_cache[sec]
    if s then return s end
    s = {}
    for _, e in ipairs(sec.block) do
        if e.op and e.key and e.key.text == "component_slot" and e.value.text == nil then
            local tname = unq(defs.field(e.value, "template"))
            local td = tname and defs.get("common/component_slot_templates", tname)
            s[#s + 1] = { name = unq(defs.field(e.value, "name")), size = td and unq(defs.field(td.block, "size")),
                          kind = td and unq(defs.field(td.block, "component")) or "weapon" }
        end
    end
    for _, x in ipairs(SLOT_NAMES) do
        local n = tonumber(defs.field(sec.block, x[1])) or 0
        for k = 1, n do
            s[#s + 1] = { name = x[2] .. k, size = x[3], kind = "utility" }
        end
    end
    slots_cache[sec] = s
    return s
end

local function weapon_candidates(slot, d)
    local out = {}
    local n = 0
    for _, c in ipairs(components().list) do
        local i = cinfo(c)
        if i.weapon then
            -- the index in the database's weapon list (the tie rule's)
            n = n + 1
            if i.size == slot.size then
                local w = weight_of(defs.field(c.block, "ai_weight"), c.file, d)
                if w > 0 and component_ok(c, d) then
                    out[#out + 1] = { c = c, w = w, index = n - 1 }
                end
            end
        end
    end
    return out
end

local function fillable(sec, d)
    for _, slot in ipairs(section_slots(sec)) do
        if slot.kind == "weapon" and #weapon_candidates(slot, d) == 0 then
            return false
        end
    end
    return true
end

-- FindRandomSectionTemplate
local function find_section(slot_name, d, rng, role)
    local first_any, first_fill, best_any, best_fill, roll_any, roll_fill
    for _, sec in ipairs(sections().list) do
        local b = sec.block
        local sizes = set_of(b, "ship_size")
        if sizes[d.size] and unq(defs.field(b, "fits_on_slot")) == slot_name and has_techs(d.country, list_of(b, "prerequisites"))
            and (role == "" or set_of(b, "ai_tags")[role]) then
            first_any = first_any or sec
            local fill = fillable(sec, d)
            if fill then first_fill = first_fill or sec end
            local w = math.floor(weight_of(defs.field(b, "ai_weight"), sec.file, d) + 1e-9)
            if w > 0 then
                local roll = rng:int() % w
                if best_any == nil or roll > roll_any then best_any, roll_any = sec, roll end
                if fill and (best_fill == nil or roll > roll_fill) then best_fill, roll_fill = sec, roll end
            end
        end
    end
    if first_fill then
        return best_fill or first_fill
    end
    return best_any or first_any
end

local function placed_share_tags(stage, i)
    local n = 0
    for _, sec in ipairs(stage.sections) do
        for _, pc in ipairs(sec.components) do
            local pi = pc.info
            if pi then
                for t in pairs(i.tags) do
                    if pi.tags[t] then n = n + 1; break end
                end
            end
        end
    end
    return n
end

local function station_class(class)
    return class == "shipclass_starbase" or class == "shipclass_military_station"
end

local function add_weapons(stage, d)
    local D = defines()
    for _, sec in ipairs(stage.sections) do
        for _, slot in ipairs(section_slots(sec.def)) do
            if slot.kind == "weapon" and not sec.filled[slot.name] then
                local best, best_score
                for _, cand in ipairs(weapon_candidates(slot, d)) do
                    local i = cinfo(cand.c)
                    local score = 10 - i.power
                    if d.prefs.weapon and i.tags[d.prefs.weapon] then
                        score = score * (station_class(d.class) and D.starbase_pref or D.pref)
                    end
                    if d.role ~= "" and i.ai_tags[d.role] then
                        score = score * D.role
                    end
                    score = score / (1 + D.stacking * placed_share_tags(stage, i))
                    score = score * cand.w
                    if best == nil or score > best_score + 1e-9
                        or (math.abs(score - best_score) <= 1e-9 and bit.band(bit.bxor(d.country % 2147483648, cand.index), 1) == 0) then
                        best, best_score = cand.c, score
                    end
                end
                if best then
                    sec.components[#sec.components + 1] = { slot = slot.name, template = best.key, info = cinfo(best) }
                    sec.filled[slot.name] = true
                end
            end
        end
    end
end

local SIZE_W = { small = 1, medium = 2, large = 4 }
local function add_utilities(stage, d)
    local D = defines()
    for _, sec in ipairs(stage.sections) do
        for _, slot in ipairs(section_slots(sec.def)) do
            if slot.kind == "utility" and not sec.filled[slot.name] then
                local armor, shield, total = 0, 0, 0
                for _, s2 in ipairs(stage.sections) do
                    for _, pc in ipairs(s2.components) do
                        local pi = pc.info
                        if pi and pi.utility and pi.size ~= "aux" then
                            local w = SIZE_W[pi.size] or 1
                            if pi.armor then armor = armor + w elseif pi.shield then shield = shield + w end
                            if pi.armor or pi.shield or pi.hull then total = total + w end
                        end
                    end
                end
                local want
                if slot.size ~= "aux" then
                    local da = d.prefs.armor - (total > 0 and armor / total or 0)
                    local ds = d.prefs.shields - (total > 0 and shield / total or 0)
                    want = (ds > da + 1e-9) and "shield" or "armor"
                end
                local best, bw
                for _, pass in ipairs({ want or "any", "any" }) do
                    for _, c in ipairs(components().list) do
                        local i = cinfo(c)
                        if i.utility and i.size == slot.size and (pass == "any" or i[pass]) then
                            local w = weight_of(defs.field(c.block, "ai_weight"), c.file, d)
                            if d.role ~= "" and i.ai_tags[d.role] then w = w * D.util_role end
                            if w > 0 and (best == nil or w > bw) and component_ok(c, d) then
                                best, bw = c, w
                            end
                        end
                    end
                    if best then break end
                end
                if best then
                    sec.components[#sec.components + 1] = { slot = slot.name, template = best.key, info = cinfo(best) }
                    sec.filled[slot.name] = true
                end
            end
        end
    end
end

local function add_required(stage, d)
    local D = defines()
    for _, set in ipairs(list_of(d.size_def.block, "required_component_set")) do
        local best, bw
        for _, c in ipairs(components().list) do
            local i = cinfo(c)
            if i.set == set then
                local w = weight_of(defs.field(c.block, "ai_weight"), c.file, d)
                if d.role ~= "" and i.ai_tags[d.role] then w = w * D.util_role end
                if (best == nil or w > bw) and component_ok(c, d) then
                    best, bw = c, w
                end
            end
        end
        if best then
            stage.required[#stage.required + 1] = best.key
        end
    end
end

-- designer.generate(country, size, role) -> the design's growth stage { size, sections = { {
-- template, slot, components = { { slot, template } } } }, required = { ... } } or nil
function designer.generate(country, size, role, seed)
    local sd = defs.get("common/ship_sizes", size)
    if not sd then
        return nil
    end
    local E = require("simscript.eval")
    local d = {
        country = country, size = size, size_def = sd, class = unq(defs.field(sd.block, "class")) or "shipclass_military",
        role = role or "", prefs = designer.preferences(country),
        ctx = E.new_ctx(E.S("country", country), E.S("country", country), nil, "ship design"),
    }
    local stage = { size = size, sections = {}, required = {} }
    -- the sections' rolls: CCrudeRandom(1).Seed(seed) (0 for a design with a role)
    local rng = crude(seed or 0)
    local slots = defs.field(sd.block, "section_slots")
    for _, e in ipairs(type(slots) == "table" and slots or {}) do
        if e.op and e.key then
            local name = unq(e.key.text)
            local sec = find_section(name, d, rng, d.role)
            if not sec and d.role ~= "" then
                sec = find_section(name, d, rng, "")
            end
            if sec then
                stage.sections[#stage.sections + 1] = { template = sec.key, slot = name, def = sec, components = {}, filled = {} }
            else
                S.no_section = S.no_section + 1
            end
        end
    end
    add_required(stage, d)
    for _ = 1, 2 do
        add_weapons(stage, d)
        add_utilities(stage, d)
    end
    S.generated = S.generated + 1
    return stage
end

-- the stage as plain data (a command's argument): no definitions, no flags
function designer.plain(stage)
    if not stage then return nil end
    local out = { size = stage.size, sections = {}, required = {} }
    for _, s in ipairs(stage.sections) do
        local cs = {}
        for _, c in ipairs(s.components) do cs[#cs + 1] = { slot = c.slot, template = c.template } end
        out.sections[#out.sections + 1] = { template = s.template, slot = s.slot, components = cs }
    end
    for _, r in ipairs(stage.required) do out.required[#out.required + 1] = r end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the save's designs

-- the growth stage of a design in the world as designer.generate returns it
local function stage_of(did)
    local info = create().design_info(did)
    if not info then return nil end
    return { size = info.size, sections = info.sections, required = info.required }
end
designer.stage_of = stage_of

-- CShipGrowthStage::IsIdenticalComponents: the same sections (template, slot) with the same
-- components (slot, template) and the same required components, in order
function designer.identical(a, b)
    if not (a and b) or a.size ~= b.size or #a.sections ~= #b.sections or #a.required ~= #b.required then
        return false
    end
    for i, s in ipairs(a.sections) do
        local t = b.sections[i]
        if s.template ~= t.template or s.slot ~= t.slot or #s.components ~= #t.components then return false end
        for j, c in ipairs(s.components) do
            local u = t.components[j]
            if c.slot ~= u.slot or c.template ~= u.template then return false end
        end
    end
    for i, r in ipairs(a.required) do
        if r ~= b.required[i] then return false end
    end
    return true
end

local function design_ids(country)
    local c = world.object("country", country)
    local out = {}
    for _, v in ipairs(world.list(world.path(c, "ship_design_collection", "ship_design"))) do
        out[#out + 1] = tonumber(v)
    end
    return out
end
designer.design_ids = design_ids

local function name_key_of(did)
    local d = world.object("ship_design", did)
    local n = d and world.field(d, "name")
    if type(n) == "table" then
        local k = world.field(n, "key")
        local vars = world.field(n, "variables")
        if vars == nil then return unq(k) end
        return nil -- a formatted name (SUFFIX_NAME_FORMAT): compared by its key only
    end
    return nil
end
designer.name_key_of = name_key_of

-- the country's design with that name and size (CShipDesignCollection::GetDesignByNameAndSize)
function designer.by_name_and_size(country, name, size)
    if not name then return nil end
    for _, did in ipairs(design_ids(country)) do
        local info = create().design_info(did)
        if info and info.size == size and name_key_of(did) == name then
            return did
        end
    end
    return nil
end

-- the newest of the country's designs of the size with identical components
function designer.find_identical(country, stage)
    local ids = design_ids(country)
    for k = #ids, 1, -1 do
        local did = ids[k]
        local s = stage_of(did)
        if s and designer.identical(s, stage) then
            return did
        end
    end
    return nil
end

-- TakeRandomShipClassNameForDesign(size, country, r) [I]: from the country's name list's ship
-- names of the size (the generic ones when it has none), the first of (r + i) % n, i = 0..99,
-- that none of its designs is named
function designer.class_name(country, size, r)
    local own, generic = create().name_lists(country, size)
    local list = #own > 0 and own or generic
    if #list == 0 then
        return "SHIP_DESIGN_" .. size
    end
    local used = {}
    for _, did in ipairs(design_ids(country)) do
        local k = name_key_of(did)
        if k then used[k] = true end
    end
    for i = 0, 99 do
        local key = list[(r + i) % #list + 1]
        if not used[key] then return key end
    end
    return list[r % #list + 1]
end

-- the design's block in the save's form
local function design_block(country, stage, name, role)
    local c = world.object("country", country)
    local b = {}
    local nb = {}
    world.append(nb, "key", name, true)
    world.append(b, "name", nb)
    if role and role ~= "" then
        world.append(b, "role", role, true)
    end
    world.append(b, "upgrade_ship_components", "yes")
    world.append(b, "graphical_culture", unq(world.field(c, "graphical_culture")) or "", true)
    local gs = {}
    local st = {}
    world.append(st, "ship_size", stage.size, true)
    for _, sec in ipairs(stage.sections) do
        local sb = {}
        world.append(sb, "template", sec.template, true)
        world.append(sb, "slot", sec.slot, true)
        for _, comp in ipairs(sec.components) do
            local cb = {}
            world.append(cb, "slot", comp.slot, true)
            world.append(cb, "template", comp.template, true)
            world.append(sb, "component", cb)
        end
        world.append(st, "section", sb)
    end
    for _, r in ipairs(stage.required) do
        world.append(st, "required_component", r, true)
    end
    world.push(gs, st)
    world.append(b, "growth_stages", gs)
    return b
end

-- CCreateOrUpdateShipDesignCommand::Execute (0x431f9a0): the design added to the country's
-- collection (CShipDesignCollection::CreateOrUpdateShipDesign: one of the same name replaced and
-- its fleet templates retrofitted [not modelled: a new name each time]), then one draw of the
-- synchronized generator for the scope and on_ship_designed (this = the country)
function designer.execute_create(country, stage, name, role)
    local id, slot = create().allocate("ship_design")
    create().place("ship_design", id, slot, design_block(country, stage, name, role))
    local c = world.object("country", country)
    local coll = world.field(c, "ship_design_collection")
    if type(coll) ~= "table" then
        coll = world.child(c, "ship_design_collection")
    end
    local list = world.field(coll, "ship_design")
    if type(list) ~= "table" then
        list = world.child(coll, "ship_design")
    end
    world.append_value(list, id)
    RUST.rand()
    create().on_action("on_ship_designed", { "country", country }, nil)
    S.created = S.created + 1
    return id
end

function designer.report()
    return string.format("ai designer: %d designs generated, %d existing ones reused, %d posted, %d created, %d slots without a section",
        S.generated, S.reused, S.posted, S.created, S.no_section)
end

return designer
