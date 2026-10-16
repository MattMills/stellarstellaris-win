-- render/windows/alerts.lua : the alerts over the main screen (interface/alerts.gui
-- `alerticon_window`, CAlertManager; docs/windows/outliner.md): which of common/alerts.txt's
-- alerts the player's country shows, read from the world (engine.world) on the simulation's
-- thread by render.galaxy.
--
--   local alerts = require("render.windows.alerts").extract(game_dir, { player = id, country = obj })
--   -- { { key, icon, priority }, ... } in the order they are shown

local world = require("engine.world")
local source = require("stellar.script.source")

local M = {}

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- common/alerts.txt: key -> { icon, priority, id }
local defs_cache = {}
function M.definitions(game_dir)
    local defs = defs_cache[game_dir]
    if defs then
        return defs
    end
    defs = {}
    local tree = source.parse(game_dir, "common/alerts.txt")
    local list = tree and field(tree, "alerts")
    for _, e in ipairs(type(list) == "table" and list or {}) do
        if e.op and e.key and type(e.value) == "table" then
            defs[e.key.text] = {
                icon = tostring(field(e.value, "icon") or ""):gsub('"', ""),
                priority = tostring(field(e.value, "priority") or "LOW"),
                id = tonumber(field(e.value, "id")),
            }
        end
    end
    defs_cache[game_dir] = defs
    return defs
end

function M.extract(game_dir, ctx)
    local pc, player = ctx.country, ctx.player
    local alert_defs = M.definitions(game_dir)
    local alerts = {}
    local function alert(key, banner)
        local d = alert_defs[key] or {}
        alerts[#alerts + 1] = { key = key, icon = d.icon or "", priority = banner or d.priority or "LOW" }
    end
    if not pc then
        return alerts
    end
    -- the research alerts (ShouldShowTechAlert): a research area with nothing researched (no
    -- `<area>_queue`)
    local ts = world.field(pc, "tech_status")
    if type(ts) == "table" then
        for _, area in ipairs({ "physics", "society", "engineering" }) do
            local q = world.field(ts, area .. "_queue")
            if not (type(q) == "table" and #world.blocks(q) > 0) then
                alert("alert_" .. area .. "_research", (alert_defs["alert_" .. area .. "_research"] or {}).priority or "MEDIUM")
            end
        end
    end
    -- alert_unlock_tradition (CCountry::CanActivateAnyTradition) [I]: the unity for the next
    -- tradition, (TRADITION_COST_AMOUNTS 300 + (TRADITION_COST_TRADITION 8 x adopted) ^
    -- TRADITION_COST_TRADITION_EXP 1.8) x (1 + EMPIRE_SIZE_TRADITION_COST_PENALTY 0.002 x
    -- empire size); the cost modifiers and the empire size's base not applied
    local adopted = #world.list(world.field(pc, "traditions"))
    local unity = tonumber(world.path(pc, "modules", "standard_economy_module", "resources", "unity")) or 0
    local size = tonumber(world.field(pc, "empire_size")) or 0
    if unity >= (300 + (8 * adopted) ^ 1.8) * (1 + 0.002 * size) then
        alert("alert_unlock_tradition")
    end
    -- alert_first_contact_stage_done: a first contact of the player's (country first_contact
    -- contacts) in progress with its stage's event pending (sorts MEDIUM, its banner LOW)
    for _, cid in ipairs(world.list(world.path(pc, "first_contact", "contacts"))) do
        local c = world.object("first_contact", tonumber(cid))
        local ev = c and world.field(c, "event")
        if c and tonumber(world.field(c, "owner")) == player and world.field(c, "status") == "in_progress"
            and type(ev) == "table" and world.field(ev, "expired") ~= "yes" then
            alert("alert_first_contact_stage_done", "LOW")
            break
        end
    end
    -- alert_council_agenda_ready_for_activation (CGovernment::IsAgendaFinished): the agenda's
    -- progress at its cost (@base_agenda_cost 7000) [I: modifiers to the cost not applied]
    local progress = tonumber(world.path(pc, "government", "council_agenda_progress"))
    if progress and progress >= 7000 then
        alert("alert_council_agenda_ready_for_activation")
    end
    return alerts
end

return M
