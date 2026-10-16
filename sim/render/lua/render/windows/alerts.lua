-- render/windows/alerts.lua : the alerts over the main screen (interface/alerts.gui
-- `alerticon_window`, CAlertManager; docs/windows/outliner.md): which of common/alerts.txt's
-- alerts the player's country shows, read from the world (engine.world) on the simulation's
-- thread by render.galaxy.
--
--   local alerts = require("render.windows.alerts").extract(game_dir, { player = id, country = obj })
--   -- { { key, icon, priority }, ... } in the order they are shown
--
-- The game (4.5.2 Linux, CAlertManager::Update) evaluates one alert a frame, round robin over the
-- 66 of the ALERT enum (common/alerts.txt's order), and adds a shown one after the others of its
-- type's priority (HIGH, MEDIUM, LOW: alerts.txt `priority`): after a load, by priority then
-- enum order. What is shown here is that order once every alert has been evaluated (the game's
-- first frames show fewer: the sweep takes 66 frames). The banner may differ from the priority it
-- sorts by (code overrides). Conditions read from the save; those of mechanics a normal empire
-- has not (DLC, federations, wars, espionage, MIA fleets) are left out.

local world = require("engine.world")
local source = require("stellar.script.source")

local M = {}

local NONE = 4294967295

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function unquote(v)
    return v ~= nil and (tostring(v):gsub('"', "")) or nil
end

-- common/alerts.txt: key -> { icon, priority, order }
local defs_cache = {}
function M.definitions(game_dir)
    local defs = defs_cache[game_dir]
    if defs then
        return defs
    end
    defs = {}
    local tree = source.parse(game_dir, "common/alerts.txt")
    local list = tree and field(tree, "alerts")
    local n = 0
    for _, e in ipairs(type(list) == "table" and list or {}) do
        if e.op and e.key and type(e.value) == "table" then
            n = n + 1
            defs[e.key.text] = {
                icon = unquote(field(e.value, "icon") or ""),
                priority = tostring(field(e.value, "priority") or "LOW"):upper(),
                order = n,
            }
        end
    end
    defs_cache[game_dir] = defs
    return defs
end

-- the defines read (any section of common/defines)
local defines_cache = {}
local function defines(game_dir)
    local d = defines_cache[game_dir]
    if d then
        return d
    end
    d = {}
    for _, rel in ipairs(source.files(game_dir, "common/defines", "txt")) do
        for _, sec in ipairs(source.parse(game_dir, rel) or {}) do
            if sec.op and type(sec.value) == "table" and sec.value.text == nil then
                for _, e in ipairs(sec.value) do
                    if e.op and e.key and e.value and e.value.text then
                        d[e.key.text] = tonumber(e.value.text) or d[e.key.text]
                    end
                end
            end
        end
    end
    defines_cache[game_dir] = d
    return d
end

local RANK = { HIGH = 0, MEDIUM = 1, LOW = 2 }

function M.extract(game_dir, ctx)
    local pc, player = ctx.country, ctx.player
    local alert_defs = M.definitions(game_dir)
    local def = defines(game_dir)
    local shown = {}
    -- an alert shown (banner: a priority the code sets in place of the type's)
    local function alert(key, banner)
        local d = alert_defs[key] or {}
        shown[#shown + 1] = { key = key, icon = d.icon or "", priority = banner or d.priority or "LOW", rank = RANK[d.priority or "LOW"] or 2, order = d.order or 999 }
    end
    if not pc then
        return shown
    end
    if not world.colony_planet and world.index then
        world.index()
    end
    local gov = world.field(pc, "government")
    local empire_size = tonumber(world.field(pc, "empire_size")) or 0
    -- the empire size over its base (CCountry::GetEmpireSizeEffectScale: EMPIRE_SIZE_BASE 100;
    -- the admin cap modifiers [I: not summed])
    local excess = math.max(0, empire_size - (def.EMPIRE_SIZE_BASE or 100))
    local stock = world.path(pc, "modules", "standard_economy_module", "resources")
    local function stockpile(r)
        return tonumber(stock and world.field(stock, r)) or 0
    end

    -- 1-3: research (ShouldShowTechAlert): an area with nothing being researched (no
    -- `<area>_queue`) [V]
    local ts = world.field(pc, "tech_status")
    if type(ts) == "table" then
        for _, area in ipairs({ "physics", "society", "engineering" }) do
            local q = world.field(ts, area .. "_queue")
            if not (type(q) == "table" and #world.blocks(q) > 0) then
                alert("alert_" .. area .. "_research")
            end
        end
    end

    -- 7: low stability (a colony under LOW_PLANET_STABILITY) [V]
    for _, c in ipairs(world.list(world.field(pc, "owned_planets"))) do
        local col = world.object("colony", tonumber(c))
        local s = col and tonumber(world.field(col, "stability"))
        if s and s < (def.LOW_PLANET_STABILITY or 25) then
            alert("alert_low_stability")
            break
        end
    end

    -- 16: a resource short (HasResourceShortage: none in stock and the month's balance below
    -- zero [I]); its banner HIGH (set by code) [V]
    local balance = {}
    local bal = world.path(pc, "budget", "current_month", "balance")
    if type(bal) == "table" then
        for _, cat in ipairs(bal) do
            if cat.op and type(cat.value) == "table" then
                for _, e in ipairs(cat.value) do
                    if e.op and e.key and e.value and e.value.text then
                        balance[e.key.text] = (balance[e.key.text] or 0) + (tonumber(e.value.text) or 0)
                    end
                end
            end
        end
    end
    for _, r in ipairs({ "energy", "minerals", "food", "consumer_goods", "alloys" }) do
        if stockpile(r) <= 0 and (balance[r] or 0) < 0 then
            alert("alert_resource_shortage", "HIGH")
            break
        end
    end

    -- 17: a tradition can be adopted (CCountry::CanActivateAnyTradition: its cost in unity,
    -- CTraditionType::CalcCost) [V]: 300 + (8 x adopted) ^ 1.8 (no second term with none),
    -- x (1 + 0.002 x the empire size over its base) [I: the cost modifiers not summed]
    local adopted = #world.list(world.field(pc, "traditions"))
    local cost = (def.TRADITION_COST_AMOUNTS or 300)
    if adopted > 0 then
        cost = cost + (adopted * (def.TRADITION_COST_TRADITION or 8)) ^ (def.TRADITION_COST_TRADITION_EXP or 1.8)
    end
    cost = cost * (1 + (def.EMPIRE_SIZE_TRADITION_COST_PENALTY or 0.002) * excess)
    if stockpile("unity") >= cost then
        alert("alert_unlock_tradition")
    end

    -- 38: a first contact's stage done (a contact in progress with its stage's event pending);
    -- its banner LOW [V for the rule; I for the save's fields]
    for _, cid in ipairs(world.list(world.path(pc, "first_contact", "contacts"))) do
        local c = world.object("first_contact", tonumber(cid))
        local ev = c and world.field(c, "event")
        if c and tonumber(world.field(c, "owner")) == player and world.field(c, "status") == "in_progress"
            and type(ev) == "table" and world.field(ev, "expired") ~= "yes" then
            alert("alert_first_contact_stage_done", "LOW")
            break
        end
    end

    -- the leaders: 40 unspent trait points (a leader with `available_trait`), 41 unassigned (a
    -- leader not the ruler, of a class that is not an envoy's, with no location) [V for the rules;
    -- I for the save's fields]
    local ruler = tonumber(world.field(pc, "ruler"))
    -- (the recruitment pool's candidates are not the country's leaders)
    local pool = {}
    for _, v in ipairs(world.list(world.path(pc, "modules", "standard_leader_module", "leaders"))) do
        pool[tonumber(v)] = true
    end
    local traits, idle = false, false
    for _, lid in ipairs(world.leaders_of and world.leaders_of[player] or {}) do
        local l = world.object("leader", lid)
        if l and not pool[lid] then
            if world.field(l, "available_trait") ~= nil then
                traits = true
            end
            local class = unquote(world.field(l, "class"))
            if lid ~= ruler and class ~= "envoy" and world.field(l, "location") == nil then
                idle = true
            end
        end
    end
    if traits then
        alert("alert_unspent_leader_trait_points")
    end
    if idle then
        alert("alert_unassigned_leader")
    end

    -- the council: 42 no agenda chosen, 43 a council slot unpicked (picked_council_types under
    -- unlocked_civic_council_slots), 44 the agenda's progress at its cost (CCouncilAgenda::GetCost:
    -- @base_agenda_cost 7000 x (1 + 0.001 x the empire size over its base)), 45 a council position
    -- without a leader [V]
    if type(gov) == "table" then
        local agenda = world.field(gov, "council_agenda")
        if agenda == nil then
            alert("alert_available_council_agenda")
        end
        local picked = #world.list(world.field(gov, "picked_council_types"))
        if picked < (tonumber(world.field(gov, "unlocked_civic_council_slots")) or 0) then
            alert("alert_available_council_position")
        end
        local progress = tonumber(world.field(gov, "council_agenda_progress"))
        local agenda_cost = 7000 * (1 + (def.EMPIRE_SIZE_COUNCIL_AGENDA_COST_PENALTY or 0.001) * excess)
        if agenda and progress and progress >= agenda_cost then
            alert("alert_council_agenda_ready_for_activation")
        end
        for _, pid in ipairs(world.list(world.field(gov, "council_positions"))) do
            local p = world.object("council_positions", tonumber(pid))
            local leader = p and tonumber(world.field(p, "leader"))
            if p and (not leader or leader == NONE) then
                alert("alert_open_council_position")
                break
            end
        end
    end

    -- the order shown: by the type's priority, then the enum's (alerts.txt) order (AddAlert) [V]
    table.sort(shown, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return a.order < b.order
    end)
    for _, a in ipairs(shown) do
        a.rank, a.order = nil, nil
    end
    return shown
end

return M
