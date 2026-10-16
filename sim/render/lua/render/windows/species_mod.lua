-- render/windows/species_mod.lua : the species view's template windows (docs/windows/empire.md
-- section 14):
--
--   species_mod_window         CSpeciesModWindow (interface/species_mod_window.gui): Create /
--                              Modify Template. The template's traits (current_traits_container),
--                              the planet preference, the positive and negative traits it may take,
--                              the trait points and picks left; Save (create_new_template), Update and
--                              Delete (a template with no pops), Apply (create, then the apply window)
--   species_mod_apply_window   CSpeciesModApplyWindow (interface/species_mod_apply_window.gui): Apply
--                              This Template. The template, the species of its base on the owned
--                              colonies with their colonies (checked), the pops chosen, the cost
--
-- The windows are the species view's state: sm = the species edited, sm_traits its traits as
-- edited (a comma list, "-" none), sm_pos / sm_neg the lists' first rows; sm_apply = the template
-- applied, sm_off the species left out (a comma list). The commands are the simulation's
-- (cmd:species:create_template, update_template, delete_template, apply_template). The traits'
-- rules are the empire creator's (render.creator_rules: shown, opposites, points and picks).

local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")

local SM = {}

local FILE = "interface/species_mod_window.gui"
local AFILE = "interface/species_mod_apply_window.gui"
local W = "/species_mod_window/"
local A = "/species_mod_apply_window/"
SM.KEYS = { "sm", "sm_traits", "sm_pos", "sm_neg", "sm_apply", "sm_off" }

local function rules_of(ctx)
    local rules = require("render.creator_rules")
    return rules, rules.load(ctx.game_dir)
end

local function split(s)
    local out = {}
    for k in tostring(s or ""):gmatch("[^,]+") do
        if k ~= "-" then
            out[#out + 1] = k
        end
    end
    return out
end

local function join(list)
    return #list > 0 and table.concat(list, ",") or "-"
end

local function find(d, id)
    for _, s in ipairs(d.species or {}) do
        if tostring(s.id) == tostring(id) then
            return s
        end
    end
    return nil
end
SM.find = find

-- the creator's design for a species with traits (the country's government for the traits'
-- ethics and government rules)
local function design(d, s, traits)
    return {
        ethics = d.ethics or {}, authority = d.authority, civics = d.civics or {}, origin = d.origin,
        species = { class = s.class, portrait = s.portrait, traits = traits },
    }
end

-- whether the country may modify the species (game rule can_modify_species [I: its main tests]):
-- biological and lithoid ones with tech_gene_tailoring, robots with tech_robomodding (or
-- tech_robomodding_m), not those with trait_self_modified / trait_malleable_genes; a pre-sapient
-- not; the reason's key when not
function SM.can_modify(ctx, d, s)
    local _, R = rules_of(ctx)
    local cls = R.class[s.class or ""]
    local arch = cls and cls.archetype or "BIOLOGICAL"
    local techs = d.facts and d.facts.techs or {}
    for _, t in ipairs(s.traits or {}) do
        if t == "trait_self_modified" or t == "trait_malleable_genes" then
            return false, "CANNOT_MODIFY_SPECIES"
        end
    end
    if arch == "PRESAPIENT" then
        return false, "CANNOT_MODIFY_PRESAPIENT"
    elseif arch == "ROBOT" or arch == "MACHINE" then
        if not (techs.tech_robomodding or techs.tech_robomodding_m) then
            return false, "CANNOT_MODIFY_SPECIES"
        end
    elseif not techs.tech_gene_tailoring then
        return false, "NEEDS_GENE_TAILORING_OR_INTERGRATED_ANATOMY"
    end
    return true
end

-- Create Template (CanCreateTemplateFrom: may modify, a species of its base on the owned colonies)
-- and Apply This Template (CanApplyTemplate: another species of its base there, no modification
-- running [I: the running projects not read])
function SM.can_create(ctx, d, s)
    local ok, why = SM.can_modify(ctx, d, s)
    if not ok then
        return false, why
    end
    for _, o in ipairs(d.species or {}) do
        if o.base == s.base and (o.pops or 0) > 0 then
            return true
        end
    end
    return false, "NOT_ON_OWNED_PLANET"
end

function SM.can_apply(ctx, d, s)
    local ok, why = SM.can_modify(ctx, d, s)
    if not ok then
        return false, why
    end
    for _, o in ipairs(d.species or {}) do
        if o.base == s.base and o.id ~= s.id and (o.pops or 0) > 0 then
            return true
        end
    end
    return false, "SPECIES_MODIFICATION_NO_APPLICABLE_POP_ON_OWNED_PLANET"
end

function SM.open_editor(s)
    return "view_set:sm=" .. s.id .. ";sm_traits=" .. join(s.traits or {}) .. ";sm_pos=;sm_neg=;sm_apply=;sm_off="
end

function SM.open_apply(s)
    return "view_set:sm=;sm_traits=;sm_apply=" .. s.id .. ";sm_off="
end

local CLOSE = "view_set:sm=;sm_traits=;sm_pos=;sm_neg=;sm_apply=;sm_off="
SM.CLOSE = CLOSE

local function trait_icon(ctx, b, key, x, y, size, path)
    leaders.trait_icon(ctx, b, key, x, y, size, path)
end

local function hit(ctx, b, path, x, y, w, h, action)
    local inv = ctx.db.sprites.GFX_invisible
    if action and inv and inv.texture then
        b.items[#b.items + 1] = {
            kind = "sprite", path = path .. "/hit", sprite = "GFX_invisible", texture = inv.texture,
            sprite_kind = "spriteType", frame = 1, frames = inv.frames or 1, x = x, y = y, w = w, h = h,
            button = { name = path, action = action },
        }
    end
end

local function text_item(b, path, s, rect, font)
    b.items[#b.items + 1] = {
        kind = "text", path = path, font = font or "cg_16b", text = s,
        spans = { { text = s, colour = { 1, 1, 1 } } }, x = rect.x + 4, y = rect.y, w = rect.w - 8, h = rect.h,
        format = "left", valign = "center", fixed = true,
    }
end

-- the editor
local function editor(ctx, b, d, state)
    local s = find(d, state.sm)
    if not s then
        return
    end
    local rules, R = rules_of(ctx)
    local traits = state.sm_traits and split(state.sm_traits) or s.traits or {}
    local des = design(d, s, traits)
    local points = rules.trait_points_left(R, des)
    local picks = rules.trait_picks_left(R, des)
    -- the template differs from the species, and is valid (points and picks not overspent)
    local changed = join(traits) ~= join(s.traits or {})
    local valid = points >= 0 and picks >= 0
    local template_free = s.template and (s.pops or 0) == 0
    local function action(list, extra)
        return "cmd:species:" .. list .. "#" .. (extra or CLOSE:sub(10))
    end
    local r = b:add(FILE, "species_mod_window", {
        hide = { species_portrait = true, species_portrait_click_to_edit = true, randomize = true, generate_adjective = true },
        text = {
            [W .. "title"] = "GENE_MODIFICATION",
            [W .. "points"] = C.raw(ctx, "POINTS_LEFT"):gsub("%$POINTS[^$]*%$", "§H" .. points .. "§!"),
            [W .. "picks"] = C.raw(ctx, "PICKS_LEFT"):gsub("%$POINTS[^$]*%$", "§H" .. picks .. "§!"),
        },
        disabled = {
            [W .. "create_new_template"] = not (changed and valid) or nil,
            [W .. "apply_new_template"] = not (changed and valid) or nil,
            [W .. "update_template"] = not (template_free and changed and valid) or nil,
            [W .. "delete_template"] = not template_free or nil,
        },
        actions = {
            [W .. "close"] = CLOSE,
            [W .. "create_new_template"] = (changed and valid) and action("create_template:" .. s.id .. ":" .. join(traits) .. ":0") or nil,
            [W .. "apply_new_template"] = (changed and valid) and action("create_template:" .. s.id .. ":" .. join(traits) .. ":1") or nil,
            [W .. "update_template"] = (template_free and changed and valid) and action("update_template:" .. s.id .. ":" .. join(traits)) or nil,
            [W .. "delete_template"] = template_free and action("delete_template:" .. s.id) or nil,
        },
    })
    -- the names (the edit boxes: the species' own [I: not editable here])
    for box, v in pairs({ name = s.name, adjective = s.adjective, plural = s.plural }) do
        local rect = r.rects[W .. box]
        if rect and v then
            b:texture(W .. box .. "/bg", "gfx/interface/tiles/small_tiles_dialog.dds", rect.x, rect.y, rect.w, rect.h)
            text_item(b, W .. box .. "/text", C.name(ctx, v), rect)
        end
    end
    -- the planet preference (its own row) and the other traits (a click takes one off)
    local pref, rest = nil, {}
    for _, t in ipairs(traits) do
        if t:match("^trait_pc_.*_preference$") then
            pref = t
        else
            rest[#rest + 1] = t
        end
    end
    local pr = r.rects[W .. "planet_class_traits_container/traits"]
    if pref and pr then
        trait_icon(ctx, b, pref, pr.x, pr.y + 5, 29, "/species_mod/pref")
    end
    local cr = r.rects[W .. "current_traits_container/traits"]
    if cr then
        C.overlap(b, cr, #rest, 29, 2, function(i, x, y, prefix)
            trait_icon(ctx, b, rest[i], x, y + 5, 29, "/species_mod/current/" .. i)
            local without = {}
            for _, t in ipairs(traits) do
                if t ~= rest[i] then
                    without[#without + 1] = t
                end
            end
            hit(ctx, b, "/species_mod/current/" .. i, x, y, 29, 44, "view_set:sm_traits=" .. join(without))
        end)
    end
    -- the traits it may take: shown for the species (the creator's rules), split by their cost's sign
    local pos, neg = {}, {}
    for _, t in ipairs(rules.trait_list(R, des)) do
        if t.cost > 0 then
            pos[#pos + 1] = t
        else
            neg[#neg + 1] = t
        end
    end
    local function list(container, items, key)
        local lr = r.rects[W .. container .. "/traits"]
        if not lr then
            return
        end
        local rows = math.floor(math.min(lr.h, 244) / 34)
        local first = math.max(0, math.min(tonumber(state[key]) or 0, #items - rows))
        SM.lists = SM.lists or {}
        SM.lists[key] = { x = lr.x, y = lr.y, w = lr.w, h = rows * 34, max = math.max(0, #items - rows) }
        for i = 1, rows do
            local t = items[first + i]
            if not t then
                break
            end
            local y = lr.y + (i - 1) * 34
            local prefix = "/species_mod/" .. key .. "/" .. i
            local P = prefix .. "/species_mod_trait_long_entry/"
            local ok = rules.can_add_trait(R, des, t.key)
            b:add(FILE, "species_mod_trait_long_entry", {
                prefix = prefix, parent = { x = lr.x, y = y, w = 175, h = 34 },
                hide = { [P .. "selection_highlight"] = true },
                text = { [P .. "name"] = (ok and "" or "§G") .. C.loc(ctx, t.key) .. (ok and "" or "§!"), [P .. "cost"] = "§Y" .. t.cost .. "§!" },
            })
            trait_icon(ctx, b, t.key, lr.x + 2, y + 2, 29, prefix .. "/icon")
            local with = {}
            for _, x in ipairs(traits) do
                with[#with + 1] = x
            end
            with[#with + 1] = t.key
            hit(ctx, b, prefix, lr.x, y, 175, 34, ok and ("view_set:sm_traits=" .. join(with)) or nil)
        end
    end
    list("positive_traits_container", pos, "sm_pos")
    list("negative_traits_container", neg, "sm_neg")
end

-- the cost of the modification (CCreateSpeciesModSpecialProjectCommand::CalcCost [I: NSpecies'
-- TRAIT_MODIFICATION_BASE_COST + per pop (TRAIT_MODIFICATION_COST_MULT x the traits' cost change +
-- MODIFICATION_COST_MULT), a pop being POP_BULK_UNIT_SIZE of a group's size; robots' own defines])
function SM.cost(ctx, d, template, chosen)
    local _, R = rules_of(ctx)
    local cls = R.class[template.class or ""]
    local robot = cls and (cls.archetype == "ROBOT" or cls.archetype == "MACHINE")
    local def = function(k, v)
        return tonumber(C.define(ctx, "NSpecies", k)) or v
    end
    local base = robot and def("ROBOT_TRAIT_MODIFICATION_BASE_COST", 750) or def("TRAIT_MODIFICATION_BASE_COST", 1500)
    local mult = robot and def("ROBOT_TRAIT_MODIFICATION_COST_MULT", 20) or def("TRAIT_MODIFICATION_COST_MULT", 10)
    local each = robot and def("ROBOT_MODIFICATION_COST_MULT", 10) or def("MODIFICATION_COST_MULT", 5)
    local function tcost(list)
        local n = 0
        for _, t in ipairs(list or {}) do
            n = n + (R.trait[t] and R.trait[t].cost or 0)
        end
        return n
    end
    local cost, pops = base, 0
    for _, s in ipairs(chosen) do
        local p = (s.pops or 0) / 100
        pops = pops + (s.pops or 0)
        cost = cost + p * (mult * math.abs(tcost(template.traits) - tcost(s.traits)) + each)
    end
    return math.floor(cost + 0.5), pops
end

-- the apply window
local function apply(ctx, b, d, state)
    local t = find(d, state.sm_apply)
    if not t then
        return
    end
    local off = {}
    for _, k in ipairs(split(state.sm_off)) do
        off[k] = true
    end
    -- ListPotentialSpecies: the owned colonies' species of the template's base, not the template,
    -- by name
    local list = {}
    for _, s in ipairs(d.species or {}) do
        if s.base == t.base and s.id ~= t.id and (s.pops or 0) > 0 and SM.can_modify(ctx, d, s) then
            list[#list + 1] = s
        end
    end
    table.sort(list, function(a, b2)
        return C.name(ctx, a.name) < C.name(ctx, b2.name)
    end)
    local chosen = {}
    for _, s in ipairs(list) do
        if not off[tostring(s.id)] then
            chosen[#chosen + 1] = s
        end
    end
    local cost, pops = SM.cost(ctx, d, t, chosen)
    local ids = {}
    for _, s in ipairs(chosen) do
        ids[#ids + 1] = tostring(s.id)
    end
    local all_off = {}
    for _, s in ipairs(list) do
        all_off[#all_off + 1] = tostring(s.id)
    end
    local r = b:add(AFILE, "species_mod_apply_window", {
        hide = { [A .. "template/species"] = true },
        text = {
            [A .. "title"] = "APPLY_GENE_MODIFICATION",
            [A .. "template/name"] = C.name(ctx, t.name),
            [A .. "template/class"] = t.class or "",
            [A .. "template/planets"] = tostring(#(t.colonies or {})),
            [A .. "template/population"] = C.short(t.pops or 0),
            [A .. "affected_pops"] = C.raw(ctx, "SPECIES_MOD_NUM_POPS"):gsub("%$COUNT[^$]*%$", "§Y" .. C.short(pops) .. "§!"),
            [A .. "cost"] = C.loc(ctx, "TECH_COST") .. " £society£ " .. cost,
        },
        frames = { [A .. "list_headers/all_selected"] = #chosen == #list and #list > 0 and 2 or 1 },
        disabled = #chosen == 0 and { [A .. "apply_template"] = true } or nil,
        actions = {
            [A .. "close"] = CLOSE,
            [A .. "list_headers/all_selected"] = "view_set:sm_off=" .. (#chosen == #list and join(all_off) or "-"),
            [A .. "apply_template"] = #chosen > 0 and ("cmd:species:apply_template:" .. t.id .. ":" .. join(ids) .. "#" .. CLOSE:sub(10)) or nil,
        },
    })
    local tr = r.rects[A .. "template/traits"]
    if tr then
        C.overlap(b, tr, #(t.traits or {}), 29, 2, function(i, x, y)
            trait_icon(ctx, b, t.traits[i], x, y + 5, 29, "/species_apply/template/" .. i)
        end)
    end
    -- the rows: a species (its checkbox toggles it), then its colonies
    local lr = r.rects[A .. "list_container/list"]
    if lr then
        local y = lr.y
        for i, s in ipairs(list) do
            if y + 52 > lr.y + lr.h then
                break
            end
            local prefix = "/species_apply/" .. i
            local P = prefix .. "/species_mod_apply_species_item/"
            local on = not off[tostring(s.id)]
            local toggled = {}
            for k in pairs(off) do
                if k ~= tostring(s.id) then
                    toggled[#toggled + 1] = k
                end
            end
            if on then
                toggled[#toggled + 1] = tostring(s.id)
            end
            b:add(AFILE, "species_mod_apply_species_item", {
                prefix = prefix, parent = { x = lr.x, y = y, w = 620, h = 52 },
                hide = { [P .. "species"] = true },
                text = {
                    [P .. "name"] = C.name(ctx, s.name), [P .. "type"] = s.class or "",
                    [P .. "planets"] = tostring(#(s.colonies or {})), [P .. "population"] = C.short(s.pops or 0),
                },
                frames = { [P .. "selected"] = on and 2 or 1 },
                actions = { [P .. "selected"] = "view_set:sm_off=" .. join(toggled) },
            })
            y = y + 52
            for k, col in ipairs(s.colonies or {}) do
                if y + 52 > lr.y + lr.h then
                    break
                end
                local cp = prefix .. "/colonies/" .. k
                local Q = cp .. "/species_mod_apply_species_planet_item/"
                b:add(AFILE, "species_mod_apply_species_planet_item", {
                    prefix = cp, parent = { x = lr.x, y = y, w = 620, h = 52 },
                    text = { [Q .. "name"] = C.name(ctx, col.name), [Q .. "type"] = col.class or "", [Q .. "population"] = C.short(col.pops or 0) },
                    frames = { [Q .. "selected"] = on and 2 or 1 },
                    hide = { [Q .. "planet_designation_icon"] = true },
                })
                y = y + 52
            end
        end
    end
end

function SM.build(ctx, b, d, state)
    if state.sm then
        editor(ctx, b, d, state)
    elseif state.sm_apply then
        apply(ctx, b, d, state)
    end
end

-- the wheel over the editor's trait lists
function SM.wheel(state, notches, x, y)
    if not state.sm or not SM.lists then
        return nil
    end
    for key, r in pairs(SM.lists) do
        local out = C.list_wheel(r, state, key, notches, x, y, r.max)
        if out then
            return out
        end
    end
    return nil
end

return SM
