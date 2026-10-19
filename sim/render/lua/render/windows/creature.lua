-- render/windows/creature.lua : the ship designer's creature designer mode (the "Space Fauna" tab,
-- CCreatureDesigner: the same .gui, type 1), docs/windows/designer.md "The creature designer".
-- RE notes: /root/re452/cd/NOTES.md on 10.5.0.6.
--
-- A creature design is its ship size's creature designer template (a global design with
-- creature_designer_template = yes, the first of the size in file order) and the mutations on
-- the slots of its mutation section (MUTATION_SECTION_NAME "mutation_section", slot "mutations",
-- six ANY_ slots): the body is always the template's (RefreshDesignAndApplyMutationsEffects
-- 0x2c93440), a mutation puts its component for the size's mutation_components_size on its slot.
--
--   creature.files(F, game_dir, each_definition, globals, h)   F.mutations, F.categories,
--                                                              F.templates, F.mut_of_comp
--   creature.family(F, size)          the sizes of the size's growth family (its templates'
--                                     upgrades_to chains, both ways), by size order
--   creature.slots(F, data)           the mutation slots the country has (mutation_slots_add)
--   creature.mutations(d)             slot -> mutation key of a design
--   creature.rebuild(F, data, size, muts)   the design of the size from its template with the
--                                     mutations on their slots (ApplyMutationsToDesign)
--   creature.build(...) / creature.popups(...) / creature.act(...)   the mode's parts

local creature = {}

local MUT_SECTION, MUT_SLOT = "mutation_section", "mutations"
local TYPES = { "offensive", "defensive", "aux" }

local function str(v)
    return v and (tostring(v):gsub('"', "")) or nil
end

-- ------------------------------------------------------------------------------ the game files

function creature.files(F, game_dir, each_definition, globals, h)
    local get = h.get
    -- mutations (CMutationDatabase, DB order: file order): type, icon, the components by size
    -- (the first listed: components[0], the one CanBuildComponent is asked of), upgrades_to,
    -- is_unique, component_slot_size_to_disable
    F.mutations, F.mutation_list, F.mut_of_comp = {}, {}, {}
    each_definition(game_dir, "common/mutations", globals, function(key, b)
        local m = { key = key, type = str(get(b, "type")) or "offensive", icon = str(get(b, "icon")),
            icon_frame = tonumber(get(b, "icon_frame")) or 1, upgrades_to = str(get(b, "upgrades_to")),
            unique = get(b, "is_unique") == "yes", disable = str(get(b, "component_slot_size_to_disable")),
            components = {}, first = nil, order = #F.mutation_list + 1 }
        local sc = get(b, "ship_components")
        for _, e in ipairs(type(sc) == "table" and sc or {}) do
            if e.op and e.key and e.value.text then
                local c = str(e.value.text)
                m.components[e.key.text] = c
                m.first = m.first or c
                F.mut_of_comp[c] = key
            end
        end
        if not F.mutations[key] then
            F.mutation_list[#F.mutation_list + 1] = m
        end
        F.mutations[key] = m
    end)
    -- ship categories, in file order (the creature picker's)
    F.categories = {}
    each_definition(game_dir, "common/ship_categories", globals, function(key)
        F.categories[#F.categories + 1] = key
    end)
    -- the creature designer templates: global ship designs with creature_designer_template = yes,
    -- the first of each stage-0 size (GetCreatureDesignerTemplate 0x24a8f20), by name too (the
    -- upgrades_to chains)
    F.templates, F.template_by_name = {}, {}
    each_definition(game_dir, "common/global_ship_designs", globals, function(kind, b)
        if kind ~= "ship_design" or get(b, "creature_designer_template") ~= "yes" then
            return
        end
        local stage = b
        local gs = get(b, "growth_stages")
        if type(gs) == "table" then
            for _, e in ipairs(gs) do
                if type(e.value) == "table" or (not e.op and type(e) == "table" and e[1]) then
                    stage = e.value or e
                    break
                end
            end
        end
        local d = { name = str(get(b, "name")), size = str(get(stage, "ship_size")), sections = {}, required = {}, upgrades_to = {} }
        for _, e in ipairs(stage) do
            if e.op and e.key and e.key.text == "section" and type(e.value) == "table" then
                local s = { template = str(get(e.value, "template")), slot = str(get(e.value, "slot")), components = {} }
                for _, c in ipairs(e.value) do
                    if c.op and c.key and c.key.text == "component" and type(c.value) == "table" then
                        s.components[str(get(c.value, "slot"))] = str(get(c.value, "template"))
                    end
                end
                d.sections[#d.sections + 1] = s
            elseif e.op and e.key and e.key.text == "required_component" and e.value.text then
                d.required[#d.required + 1] = str(e.value.text)
            end
        end
        local up = get(b, "upgrades_to")
        if type(up) == "table" then
            for _, e in ipairs(up) do
                if e.text then
                    d.upgrades_to[#d.upgrades_to + 1] = str(e.text)
                end
            end
        elseif up then
            d.upgrades_to[1] = str(up)
        end
        if d.size and not F.templates[d.size] then
            F.templates[d.size] = d
        end
        if d.name then
            F.template_by_name[d.name] = F.template_by_name[d.name] or d
        end
    end)
    -- mutation_slots_add of the technologies (the country modifier CalcAvailableMutationSlots
    -- reads, 0x1c61680) [I: the technologies' own modifier only]
    F.mut_slot_techs = {}
    each_definition(game_dir, "common/technology", globals, function(key, b)
        local m = get(b, "modifier")
        local n = type(m) == "table" and tonumber(get(m, "mutation_slots_add"))
        if n then
            F.mut_slot_techs[key] = n
        end
    end)
end

-- ------------------------------------------------------------------------------ the designs

function creature.is_creature(F, d)
    local s = d and F.sizes[d.size]
    return s ~= nil and s.fauna == true
end

-- the growth family: the templates linked by upgrades_to, both ways (GetShipSizesVariantsFrom-
-- DesignerTemplates 0x1f67da0: a flood fill over the templates) [I: newborn designs left out]
function creature.family(F, size)
    local seen, out = { [size] = true }, { size }
    local changed = true
    while changed do
        changed = false
        for s, t in pairs(F.templates) do
            for _, up in ipairs(t.upgrades_to) do
                local u = F.template_by_name[up]
                if u and u.size then
                    if seen[s] and not seen[u.size] then
                        seen[u.size], changed = true, true
                        out[#out + 1] = u.size
                    elseif seen[u.size] and not seen[s] then
                        seen[s], changed = true, true
                        out[#out + 1] = s
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (F.sizes[a] or { order = 0 }).order < (F.sizes[b] or { order = 0 }).order end)
    return out
end

-- the mutation slots the country has: its technologies' mutation_slots_add, at most the
-- section's six (CalcAvailableMutationSlots) [I: other modifier sources not counted]
function creature.slots(F, data)
    local n = 0
    for t, v in pairs(F.mut_slot_techs or {}) do
        if data.techs and data.techs[t] then
            n = n + v
        end
    end
    return math.floor(n + 0.5)
end

local function mutation_section(d)
    for _, s in ipairs(d.sections or {}) do
        if s.slot == MUT_SLOT or s.template == MUT_SECTION then
            return s
        end
    end
    return nil
end
creature.mutation_section = mutation_section

-- slot name -> mutation key (GetMutationForEachSlot)
function creature.mutations(F, d)
    local out = {}
    local s = d and mutation_section(d)
    for slot, c in pairs(s and s.components or {}) do
        out[slot] = F.mut_of_comp[c]
    end
    return out
end

local function copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = copy(x)
    end
    return out
end

-- RefreshDesignAndApplyMutationsEffects: the size's template, the mutations on their slots (the
-- section made when missing: ApplyMutationsToDesign 0x1f687c0), then each mutation's
-- component_slot_size_to_disable (DisableComponentsOfInvalidSize 0x1db4e90)
function creature.rebuild(F, data, size, muts)
    local t = F.templates[size]
    local d = { size = size, sections = copy(t and t.sections or {}), required = {} }
    -- FixRequired: the template's required components that exist, then each required set of the
    -- size without one gets the newest of the set the country has researched (else its first)
    -- [I: the choice] (the 4.5.2 amoeba template's BIO_PROPULSION_1_CORVETTE is no component)
    local have = {}
    for _, k in ipairs(t and t.required or {}) do
        local c = F.components[k]
        if c then
            d.required[#d.required + 1] = k
            have[c.set or k] = true
        end
    end
    for _, set in ipairs((F.sizes[size] or { required = {} }).required) do
        if not have[set] then
            local best, first
            for _, c in pairs(F.components) do
                if c.set == set then
                    if not first or c.order < first.order then
                        first = c
                    end
                    local ok = true
                    for _, p in ipairs(c.prerequisites or {}) do
                        ok = ok and data and data.techs and data.techs[p] == true
                    end
                    if ok and (not best or c.order > best.order) then
                        best = c
                    end
                end
            end
            local pick = best or first
            if pick then
                d.required[#d.required + 1] = pick.key
                have[set] = true
            end
        end
    end
    local s = mutation_section(d)
    if not s then
        s = { template = MUT_SECTION, slot = MUT_SLOT, components = {} }
        d.sections[#d.sections + 1] = s
    end
    s.components = {}
    local ms = F.sizes[size] and F.sizes[size].mut_size or "small"
    for slot, key in pairs(muts or {}) do
        local m = F.mutations[key]
        local c = m and m.components[ms]
        if c then
            s.components[slot] = c
        end
    end
    for _, key in pairs(muts or {}) do
        local m = F.mutations[key]
        if m and m.disable then
            for _, sec in ipairs(d.sections) do
                if sec ~= s then
                    for _, sl in ipairs((F.sections[sec.template] or { slots = {} }).slots) do
                        if sl.size == m.disable then
                            sec.components[sl.name] = nil
                        end
                    end
                end
            end
        end
    end
    return d
end

-- a mutation the country can use: its first component's prerequisites researched
-- (CanBuildComponent of components[0]) [I: the component's potential not evaluated]
local function usable(F, data, m)
    local c = m and m.first and F.components[m.first]
    if not c then
        return false
    end
    for _, t in ipairs(c.prerequisites or {}) do
        if not (data.techs and data.techs[t]) then
            return false
        end
    end
    return true
end

-- HasBetterElement 0x2c96f80: a later mutation of its upgrades_to chain is usable
local function obsolete(F, data, m)
    local seen = {}
    local u = m.upgrades_to and F.mutations[m.upgrades_to]
    while u and not seen[u.key] do
        seen[u.key] = true
        if usable(F, data, u) then
            return true
        end
        u = u.upgrades_to and F.mutations[u.upgrades_to]
    end
    return false
end

-- the categories a new creature can be made of (CCreatureSelector::Update 0x31a08e0): the
-- country's culled DNA has it (rarity not 4), and a designable size of it the country can build
-- (its potential_country's has_dna, its prerequisites [I]) with a template; the first such size
function creature.categories(F, data)
    local out = {}
    for _, cat in ipairs(F.categories) do
        if data.dna and data.dna[cat] and data.dna[cat] ~= 4 then
            for _, name in ipairs(F.size_order) do
                local s = F.sizes[name]
                if s.category == cat and s.fauna and s.designable and F.templates[name] then
                    local ok = true
                    for _, t in ipairs(s.prerequisites) do
                        ok = ok and data.techs[t] == true
                    end
                    if ok then
                        out[#out + 1] = { category = cat, size = name }
                        break
                    end
                end
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------------------ the window

-- the mutations entry (creature_mutations_instance_entry, one: UpdateMutations 0x2c94000) in the
-- sections box: change_size_button, the fixed components (the other sections' slots, read-only,
-- weapons on the first row and utilities on the second: RefreshFixedComponents 0x2c94900), the
-- mutation slots (all six; those past the country's count locked: UpdateInternalData 0x2c94ed0)
function creature.build(c)
    local ctx, F, data, design, lay, items, report, r, ui = c.ctx, c.F, c.data, c.design, c.lay, c.items, c.report, c.r, c.ui
    local box = r.rects["/ship_designer/sections"]
    if not box then
        return
    end
    local ep = "/designer/creature"
    local e = ep .. "/creature_mutations_instance_entry"
    local x0 = box.x + (box.w - 172) / 2
    local er = lay("creature_mutations_instance_entry", {
        prefix = ep, parent = { x = x0, y = box.y, w = 0, h = 0 },
        actions = { [e .. "/change_size_button"] = "designer:ui:csize" },
    })
    local function slot_cell(path, x, y, frame, icon, icon_frame, action, disabled)
        local cp = path
        local cc = cp .. "/component_slot"
        local opts = { prefix = cp, parent = { x = x, y = y, w = 0, h = 0 }, hide = { deselect = true, allowed = true }, frames = {}, sprites = {},
            actions = {}, positions = { [cc] = { 0, 0 } } }
        opts.frames[cc .. "/component_slot_button"] = frame
        if icon then
            opts.sprites[cc .. "/icon"] = icon
            opts.frames[cc .. "/icon"] = icon_frame or 1
        else
            opts.hide.icon = true
        end
        if action then
            opts.actions[cc .. "/component_slot_button"] = action
        end
        if disabled then
            opts.disabled = { [cc .. "/component_slot_button"] = true }
        end
        lay("component_slot", opts)
    end
    -- the fixed components: two rows centred on the grid's place (CENTERED_UP_BY_LINE at x 88) [I:
    -- the rows by slot kind]
    local fixed = er.rects[e .. "/fixed_components_slots"]
    if fixed then
        local rows = { {}, {} }
        for _, s in ipairs(design.sections) do
            if s.slot ~= MUT_SLOT and s.template ~= MUT_SECTION then
                for _, sl in ipairs((F.sections[s.template] or { slots = {} }).slots) do
                    local row = (sl.kind == "weapon" or sl.kind == "strike_craft") and 1 or 2
                    rows[row][#rows[row] + 1] = { sl = sl, comp = F.components[s.components[sl.name] or ""] }
                end
            end
        end
        for ri, row in ipairs(rows) do
            local w = #row * 56
            for k, it in ipairs(row) do
                local frame = c.slot_frame(it.sl)
                slot_cell(ep .. "/fixed/" .. ri .. "/" .. k, fixed.x - w / 2 + (k - 1) * 56, fixed.y + (ri - 1) * 56, frame + 1,
                    it.comp and it.comp.icon, it.comp and it.comp.icon_frame, nil, false)
            end
        end
    end
    -- the mutation slots: 3 a row from the grid's place
    local grid = er.rects[e .. "/mutation_slots"]
    local ms = mutation_section(design)
    local tpl = F.sections[MUT_SECTION]
    local n_open = creature.slots(F, data)
    if grid and tpl then
        for k, sl in ipairs(tpl.slots) do
            local comp = ms and F.components[ms.components[sl.name] or ""]
            local mut = comp and F.mutations[F.mut_of_comp[comp.key]]
            local open = k <= n_open
            local left = ui.paint_mut and ("designer:ui:mpaint:" .. sl.name) or ("designer:ui:mslot:" .. sl.name)
            local right = ui.paint_mut and "designer:ui:paint_cancel" or ("designer:ui:mclear:" .. sl.name)
            local col, row = (k - 1) % 3, math.floor((k - 1) / 3)
            -- the button: frame 2 for a unique mutation, else 1 (CMutationSlotEntry's ctor); its
            -- sprite the NInterface CREATURE_DESIGNER_MUTATION_SLOT(_LOCKED)_ICON define's, empty
            -- in these files (the component_slot's own kept); a locked slot disabled; the icon the
            -- component's (UpdateInternalData 0x2c94ed0) [V]
            slot_cell(ep .. "/mut/" .. k, grid.x + col * 56, grid.y + row * 56, (mut and mut.unique) and 2 or 1,
                comp and comp.icon, comp and comp.icon_frame,
                open and (left .. "||" .. right) or nil, not open)
        end
    end
end

-- the creature picker (selector: a selector_item per category, CSelectorItemShipCategory), the
-- size picker (selector: the family's sizes), the mutation picker (component_select_window with
-- creature_mutation_type_entry headers)
function creature.popups(c)
    local ctx, F, data, design, lay, items, report, r, ui = c.ctx, c.F, c.data, c.design, c.lay, c.items, c.report, c.r, c.ui
    local pp = ui.popup
    local win = r.rects["/ship_designer"]
    if pp.kind == "creature" or pp.kind == "csize" then
        local wr = lay("selector", {
            text = { ["/selector/title"] = pp.kind == "creature" and "NEW_DESIGN" or "PICK_CREATURE_SIZE" },
            actions = { ["/selector"] = "designer:noop", ["/selector/close"] = "designer:ui:popup_close" },
        })
        local grid = wr.rects["/selector/ship_grid_window/ship_sizes_grid"]
        local entries = {}
        if pp.kind == "creature" then
            for _, cs in ipairs(creature.categories(F, data)) do
                entries[#entries + 1] = { key = cs.category, title = cs.category, action = "designer:ui:new_cat:" .. cs.category, tooltip = cs.category .. "_desc" }
            end
        elseif design then
            -- CCreatureSizeSelector::Update 0x31a0fb0: the family's sizes the country can build
            -- potentially (CanCountryBuildPotential of their templates: the size's
            -- potential_country, its has_dna; [I] its prerequisites not asked) [I: its owned ships
            -- not counted]
            for _, s in ipairs(creature.family(F, design.size)) do
                local sz = F.sizes[s]
                local ok = sz ~= nil and F.templates[s] ~= nil
                if ok and sz.category and not (data.dna and data.dna[sz.category]) then
                    ok = false
                end
                if ok then
                    entries[#entries + 1] = { key = s, title = c.size_name(ctx, s), action = "designer:ui:set_size:" .. s, selected = s == design.size }
                end
            end
        end
        if grid then
            for k, en in ipairs(entries) do
                local x, y = grid.x + ((k - 1) % 3) * 269, grid.y + math.floor((k - 1) / 3) * 144
                if y + 139 <= grid.y + grid.h then
                    local pfx = "/designer/" .. pp.kind .. "/" .. en.key
                    local e = pfx .. "/selector_item"
                    lay("selector_item", {
                        prefix = pfx, parent = { x = x, y = y, w = 0, h = 0 }, hide = { selected = not en.selected or nil },
                        text = { [e .. "/title"] = en.title },
                        tooltips = en.tooltip and { [e .. "/choose_ship_type_button"] = en.tooltip } or nil,
                        actions = { [e .. "/choose_ship_type_button"] = en.action },
                    })
                end
            end
        end
        return
    end
    if pp.kind ~= "mutation" or not design or not win then
        return
    end
    -- component_select_window as the mutation picker (ShowMutationSelectDialog 0x2c92e00): its
    -- labels SELECT_MUTATION, SELECT_MUTATION_DESC, CREATURE_MUTATIONS_FILTER_OBSOLETE; the
    -- mutations whose first component the country can build, by type (offensive, defensive, aux:
    -- a creature_mutation_type_entry header each, its background toggling the group), the
    -- obsolete ones hidden with the filter (UpdateElementList 0x2c968a0)
    local W = "/component_select_window"
    local wr = lay("component_select_window", {
        parent = { x = win.x, y = win.y, w = 0, h = 0 },
        text = {
            [W .. "/select_component_label"] = "SELECT_MUTATION", [W .. "/select_component_desc"] = "SELECT_MUTATION_DESC",
            [W .. "/filter_obsolete_label"] = "CREATURE_MUTATIONS_FILTER_OBSOLETE",
        },
        frames = {
            [W .. "/filter_slot_size"] = ui.filter_size and 2 or 1,
            [W .. "/filter_obsolete"] = ui.hide_obsolete and 2 or 1,
        },
        hide = { current_filter_slot_size = true },
        actions = {
            [W] = "designer:noop",
            [W .. "/close"] = "designer:ui:popup_close", [W .. "/apply_on_empty"] = "designer:ui:mfill",
            [W .. "/filter_slot_size"] = "designer:ui:filter_size", [W .. "/filter_obsolete"] = "designer:ui:filter_obsolete",
        },
    })
    local list = wr.rects[W .. "/list"]
    if not list then
        return
    end
    local ms = mutation_section(design)
    local current = ms and F.mut_of_comp[ms.components[pp.slot] or ""]
    local rows = {}
    for _, t in ipairs(TYPES) do
        rows[#rows + 1] = { header = t }
        if ui.groups[t] then
            for _, m in ipairs(F.mutation_list) do
                if m.type == t and usable(F, data, m) and not (ui.hide_obsolete and obsolete(F, data, m)) then
                    rows[#rows + 1] = { m = m }
                end
            end
        end
    end
    ui.rects.component = list
    local total = 0
    for _, row in ipairs(rows) do
        total = total + (row.header and 40 or 66)
    end
    ui.extent.component = math.max(0, total - list.h)
    local y = list.y - (ui.scroll.component or 0)
    local size = F.sizes[design.size]
    for _, row in ipairs(rows) do
        local hgt = row.header and 40 or 66
        if y >= list.y and y + hgt - 6 <= list.y + list.h then
            if row.header then
                local pfx = "/designer/mtype/" .. row.header
                local e = pfx .. "/creature_mutation_type_entry"
                lay("creature_mutation_type_entry", {
                    prefix = pfx, parent = { x = list.x + 5, y = y, w = 0, h = 0 },
                    text = { [e .. "/title"] = row.header .. "_mutation_type" },
                    actions = { [e .. "/background"] = "designer:ui:mtoggle:" .. row.header },
                })
            else
                local m = row.m
                local comp = F.components[m.components[size and size.mut_size or "small"] or m.first or ""]
                local pfx = "/designer/mutations/" .. m.key
                local e = pfx .. "/component_set_entry"
                local hide = { unique_mutation_icon = not m.unique or nil }
                for nm in pairs({ pd_icon = 1, small_icon = 1, medium_icon = 1, large_icon = 1, torpedo_icon = 1, extra_large_icon = 1, titanic_icon = 1, planet_killer_icon = 1, engulf_icon = 1, aux_icon = 1, strike_craft_icon = 1 }) do
                    hide[nm] = true
                end
                if m.key ~= current and m.key ~= ui.paint_mut then
                    hide.selected_overlay = true
                end
                local stats = comp and c.resource_string(ctx, comp.cost or {}) or ""
                lay("component_set_entry", {
                    prefix = pfx, parent = { x = list.x + 5, y = y + 4, w = 0, h = 0 }, hide = hide,
                    sprites = m.icon and { [e .. "/icon"] = m.icon } or nil,
                    frames = { [e .. "/icon"] = m.icon_frame },
                    text = { [e .. "/name"] = comp and comp.key or m.key, [e .. "/stats"] = stats },
                    tooltips = m.unique and { [e .. "/unique_mutation_icon"] = "CREATURE_DESIGNER_MUTATION_IS_UNIQUE" } or nil,
                    actions = { [e .. "/component_entry_bg"] = "designer:ui:set_mut:" .. m.key },
                })
            end
        end
        y = y + hgt
    end
end

-- the mode's clicks; returns nil when the verb is not the mode's
function creature.act(c, verb, parts)
    local F, data, ui = c.F, c.data, c.ui
    local d = c.shown()
    if verb == "new" then
        -- new_ship_design_entry: ShowShipSizeSelectDialog, the creature picker in this mode
        ui.popup = { kind = "creature" }
        return ""
    elseif verb == "new_cat" and parts[2] then
        -- CSelectorItemShipCategory click 0x31a4ed0: a copy of the template of the category's first
        -- designable size, with an empty name
        for _, cs in ipairs(creature.categories(F, data)) do
            if cs.category == parts[2] then
                local w = creature.rebuild(F, data, cs.size, {})
                w.new, w.dirty, w.role, w.upgrade, w.auto_gen = true, true, "", true, false
                w.name, w.name_key, w.name_literal = { key = "", vars = {} }, "", true
                ui.works.new = w
                ui.current = "new"
            end
        end
        ui.popup = nil
        return ""
    end
    if not d then
        return nil
    end
    if verb == "csize" then
        -- change_size_button: ShowCreatureDesignSelectSizeDialog 0x3198c10
        ui.popup = { kind = "csize" }
        return ""
    elseif verb == "set_size" and parts[2] then
        -- CSelectorItemShipSize::OnClick, type 1 (GetExistingDesign 0x31a4310): the country's
        -- design of the size (the one of the same name first), the current mutations and name on
        -- it; [I] none: the size's template
        local muts = creature.mutations(F, d)
        local base
        for _, x in ipairs(data.designs or {}) do
            if x.size == parts[2] and (not base or (x.name and d.name and x.name.key == d.name.key)) then
                base = x
            end
        end
        local w = creature.rebuild(F, data, parts[2], muts)
        w.name, w.name_key, w.name_literal = c.copy(d.name), d.name_key, d.name_literal
        w.role, w.upgrade, w.auto_gen, w.dirty = d.role, d.upgrade, false, true
        if base then
            w.id = base.id
            ui.works[base.id] = w
            ui.current = base.id
        else
            w.new = true
            ui.works.new = w
            ui.current = "new"
        end
        ui.popup = nil
        -- (a new one stays the window's own: the window is not given another design)
        return base and ("design:" .. base.id) or ""
    elseif verb == "mslot" and parts[2] then
        -- CMutationSlotEntry::Click 0x2c95450: the mutation picker for the slot
        ui.popup = { kind = "mutation", slot = parts[2] }
        ui.scroll.component = 0
        return ""
    elseif verb == "mtoggle" and parts[2] then
        -- a group header: ToggleMutationType 0x2c95ee0
        ui.groups[parts[2]] = not ui.groups[parts[2]]
        return ""
    elseif verb == "set_mut" and parts[2] and F.mutations[parts[2]] then
        -- CMutationSelector::ItemClicked 0x2c96f50: the mutation selected, painted on the slots
        -- clicked next (paint mode)
        ui.paint_mut = parts[2]
        return ""
    elseif verb == "mpaint" and parts[2] and ui.paint_mut then
        -- a slot clicked while painting: refused for a unique mutation already on another slot
        -- (HasUniqueMutation 0x1f689c0, click_decline_action), else put there and the design
        -- rebuilt (RefreshDesignAndApplyMutationsEffects); painting goes on
        local w = c.work()
        local muts = creature.mutations(F, w)
        local m = F.mutations[ui.paint_mut]
        if m.unique then
            for slot, k in pairs(muts) do
                if k == m.key and slot ~= parts[2] then
                    return ""
                end
            end
        end
        muts[parts[2]] = m.key
        local nd = creature.rebuild(F, data, w.size, muts)
        w.sections, w.required, w.dirty = nd.sections, nd.required, true
        return ""
    elseif verb == "mclear" and parts[2] then
        -- a right click: the slot cleared (2c956a0)
        local w = c.work()
        local muts = creature.mutations(F, w)
        muts[parts[2]] = nil
        local nd = creature.rebuild(F, data, w.size, muts)
        w.sections, w.dirty = nd.sections, true
        return ""
    elseif verb == "mfill" and ui.paint_mut then
        -- apply_on_empty: ApplySelectedElementOnAllEmptySlots 0x2c93300 (every empty mutation slot,
        -- no unique or locked check) [V]
        local w = c.work()
        local muts = creature.mutations(F, w)
        for _, sl in ipairs((F.sections[MUT_SECTION] or { slots = {} }).slots) do
            if not muts[sl.name] then
                muts[sl.name] = ui.paint_mut
            end
        end
        local nd = creature.rebuild(F, data, w.size, muts)
        w.sections, w.dirty = nd.sections, true
        return ""
    elseif verb == "clear" then
        -- clear_button: ClearAllDesignsComponents (the template's sections again: no mutation)
        local w = c.work()
        local nd = creature.rebuild(F, data, w.size, {})
        w.sections, w.required, w.dirty = nd.sections, nd.required, true
        return ""
    end
    return nil
end

-- the variants saved (BuildAllCreatureDesignsVariants 0x1f682a0): a design of every size of the
-- family, the template's with the same name and mutations; each replaces the country's design of
-- its size and name [I]
function creature.variants(F, data, d)
    local muts = creature.mutations(F, d)
    local out = {}
    for _, s in ipairs(creature.family(F, d.size)) do
        if F.templates[s] then
            local v = creature.rebuild(F, data, s, muts)
            local base = 0
            for _, x in ipairs(data.designs or {}) do
                if x.size == s and x.name and d.name and x.name.key == d.name.key and (d.name.key or "") ~= "" then
                    base = x.id
                end
            end
            if s == d.size and d.id and not d.new then
                base = d.id
            end
            out[#out + 1] = { stage = { size = s, sections = v.sections, required = v.required }, base = base }
        end
    end
    return out
end

return creature
