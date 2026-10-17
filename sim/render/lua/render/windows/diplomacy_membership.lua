-- render/windows/diplomacy_membership.lua : leaving a federation, joining and leaving the galactic
-- community (the federation view's Leave Federation, the community view's Join / Leave), in the
-- simulation: docs/windows/diplomacy.md section 8. Each returns a Lua chunk { ok, note, ... }.
--
--   local Mb = require("render.windows.diplomacy_membership")
--   Mb.leave_federation(game_dir, player)
--   Mb.join_community(game_dir, player)
--   Mb.leave_community(game_dir, player)
--   Mb.community_costs(game_dir, player) -> join cost, leave cost, can join, can leave, reason

local world = require("engine.world")

local Mb = {}

local function serialize(t)
    return require("render.windows.diplomacy_data").serialize(t)
end

local function ref(v)
    v = tonumber(v)
    if v == nil or v == 4294967295 then
        return nil
    end
    return v
end

local function ids(block)
    local out = {}
    for _, v in ipairs(type(block) == "table" and world.list(block) or {}) do
        out[#out + 1] = tonumber(v)
    end
    return out
end

local function effects()
    pcall(require, "engine.script.creation")
    local ok, systems = pcall(require, "engine.systems")
    return ok and systems.effects or {}
end

local function today()
    return (tostring(world.meta and world.meta.date or ""):gsub('"', ""))
end

-- CGameState::CreateNewTruce(a, b, type): a truce object and each relation's `truce`
local function truce(a, b, kind)
    local A = require("render.windows.diplomacy_actions")
    local tid = world.next_index("truce")
    local t = {}
    world.create("truce", tid, t)
    world.append(t, "start_date", today(), true)
    world.set(t, "truce_type", kind)
    for _, p in ipairs({ { a, b }, { b, a } }) do
        local r = A.relation(p[1], p[2])
        if r then
            world.set(r, "truce", tid)
        end
    end
    return tid
end

local function remove_key(obj, key)
    local e = obj and world.entry(obj, key)
    if e then
        world.remove_entry(obj, e)
    end
end

-- CFederation::End: the federation gone, its members and associates without it
local function end_federation(fid, fed)
    for _, m in ipairs(ids(world.field(fed, "members"))) do
        remove_key(world.object("country", m), "federation")
    end
    for _, m in ipairs(ids(world.field(fed, "associates"))) do
        remove_key(world.object("country", m), "associated_federation")
    end
    world.remove("federation", fid)
end

-- CLeaveFederationAction::ExecuteAccept @2654c60 (auto-accepted): CFederation::RemoveMember (out of
-- `members`, its envoys out of `envoy`, its `federation` key gone, cohesion
-- FEDERATION_LEAVE_COHESION_PENALTY), then each remaining member a truce (alliance) and
-- opinion_broke_federation towards the leaver. The federation ends (CFederation::ToBeKilled) with fewer
-- than 2 members: the game at the next day's tick, here at once [I: the simulation has no federation
-- tick]. A new leader by the succession law when the leader leaves 3 or more [not done here], the
-- proposed votes' voters and the ship designs passed back [not done here].
function Mb.leave_federation(game_dir, player)
    local c = world.object("country", player)
    local fid = c and ref(world.field(c, "federation"))
    local fed = fid and world.object("federation", fid)
    if not fed then
        return serialize({ ok = false, note = "not in a federation" })
    end
    local mb = world.field(fed, "members")
    if type(mb) == "table" then
        world.remove_value(mb, player)
    end
    local prog = world.field(fed, "federation_progression")
    if type(prog) == "table" then
        local env = world.field(prog, "envoy")
        for _, l in ipairs(ids(env)) do
            local lo = world.object("leader", l)
            if lo and tonumber(world.field(lo, "country")) == player then
                world.remove_value(env, l)
            end
        end
        local coh = tonumber(world.field(prog, "cohesion")) or 0
        world.set(prog, "cohesion", math.max(-100, coh - 100))
    end
    remove_key(c, "federation")
    local rest = ids(world.field(fed, "members"))
    local fx = effects()
    for _, m in ipairs(rest) do
        truce(player, m, "alliance")
        if fx.add_opinion_modifier then
            pcall(fx.add_opinion_modifier, { kind = "country", id = m, who = player, modifier = "opinion_broke_federation" })
        end
    end
    local ended = #rest < 2
    if ended then
        end_federation(fid, fed)
    end
    return serialize({ ok = true, done = true, ended = ended, note = "left federation " .. fid .. (ended and " (ended)" or "") })
end

-- the defines of NGameplay (common/defines: the last value of a key wins)
local gameplay_cache
local function gameplay(game_dir)
    if not gameplay_cache then
        gameplay_cache = {}
        local source = require("stellar.script.source")
        for _, f in ipairs(source.files(game_dir, "common/defines", "txt")) do
            for _, top in ipairs(source.parse(game_dir, f) or {}) do
                if top.op and top.key and top.key.text == "NGameplay" and type(top.value) == "table" then
                    for _, e in ipairs(top.value) do
                        if e.op and e.key and e.value.text then
                            gameplay_cache[e.key.text] = tonumber(e.value.text)
                        end
                    end
                end
            end
        end
    end
    return gameplay_cache
end

local function community()
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "galactic_community" and type(e.value) == "table" and e.value.text == nil then
            return e.value
        end
    end
    return nil
end

local function influence(c)
    local m = world.field(c, "modules")
    local e = type(m) == "table" and world.field(m, "standard_economy_module")
    local r = type(e) == "table" and world.field(e, "resources")
    return type(r) == "table" and tonumber(world.field(r, "influence")) or 0
end

local function has_timed(c, name)
    local tm = world.field(c, "timed_modifier")
    local items = type(tm) == "table" and world.field(tm, "items")
    for _, it in ipairs(type(items) == "table" and world.blocks(items) or {}) do
        if tostring(world.field(it, "modifier") or ""):gsub('"', "") == name then
            return true
        end
    end
    return false
end

-- CJoinCommunityCommand::IsValid @26da340 and CLeaveCommunityCommand::IsValid @26daae0 (not an
-- imperium): join needs no left_galactic_community modifier and JOIN_COMMUNITY_INFLUENCE_COST
-- influence; leave costs empire sprawl x LEAVE_COMMUNITY_INFLUENCE_COST_FACTOR, clamped to
-- LEAVE_COMMUNITY_MIN/MAX_INFLUENCE_COST, and the custodian cannot leave. Subjects' voting rights and
-- the game rule not checked [I].
function Mb.community_costs(game_dir, player)
    local G = gameplay(game_dir)
    local c = world.object("country", player)
    local gc = community()
    if not c or not gc then
        return 0, 0, false, false, "no community"
    end
    local join = G.JOIN_COMMUNITY_INFLUENCE_COST or 100
    local sprawl = tonumber(world.field(c, "empire_size")) or 0
    local leave = math.max(G.LEAVE_COMMUNITY_MIN_INFLUENCE_COST or 100,
        math.min(G.LEAVE_COMMUNITY_MAX_INFLUENCE_COST or 500, sprawl * (G.LEAVE_COMMUNITY_INFLUENCE_COST_FACTOR or 0.5)))
    leave = math.floor(leave)
    local inf = influence(c)
    local can_join, can_leave, reason = true, true, nil
    if has_timed(c, "left_galactic_community") then
        can_join, reason = false, "JOIN_RECENTLY_LEFT"
    end
    if inf < join then
        can_join = false
    end
    if ref(world.field(gc, "custodian")) == player then
        can_leave, reason = false, "CANNOT_LEAVE_GALACTIC_COMMUNITY_IS_CUSTODIAN"
    end
    if inf < leave then
        can_leave = false
    end
    return join, leave, can_join, can_leave, reason
end

-- CJoinCommunityCommand::Execute @26da290: the cost paid, GC::AddMember (communications with the
-- members [not done here], `members` appended, on_galactic_community_formed for the first member,
-- on_add_community_member)
function Mb.join_community(game_dir, player)
    local gc = community()
    local join, _, can_join, _, reason = Mb.community_costs(game_dir, player)
    if not gc or not can_join then
        return serialize({ ok = false, note = "cannot join: " .. tostring(reason or "influence") })
    end
    local fx = effects()
    fx.add_resource({ kind = "country", id = player, resource = "influence", amount = -join })
    local mb = world.child(gc, "members")
    local first = #ids(mb) == 0
    world.append_value(mb, tostring(player))
    local run = {}
    local ok, eval = pcall(require, "simscript.eval")
    local okev, events = pcall(require, "simscript.events")
    if ok and okev then
        for _, name in ipairs(first and { "on_galactic_community_formed", "on_add_community_member" } or { "on_add_community_member" }) do
            local okr, err = pcall(events.on_action, name, eval.S("country", player), eval.new_ctx(eval.S("country", player), eval.S("country", player)))
            run[#run + 1] = name .. (okr and "" or (" failed: " .. tostring(err)))
        end
    end
    return serialize({ ok = true, done = true, note = "joined, -" .. join .. " influence; ran " .. table.concat(run, ", ") })
end

-- CLeaveCommunityCommand::Execute @26da7b0: the cost paid, left_galactic_community for
-- LEFT_COMMUNITY_MODIFIER_TIMER days, GC::RemoveMember (`members`, its emissaries, the council
-- [I], on_remove_community_member)
function Mb.leave_community(game_dir, player)
    local gc = community()
    local _, leave, _, can_leave, reason = Mb.community_costs(game_dir, player)
    if not gc or not can_leave then
        return serialize({ ok = false, note = "cannot leave: " .. tostring(reason or "influence") })
    end
    local fx = effects()
    fx.add_resource({ kind = "country", id = player, resource = "influence", amount = -leave })
    local days = gameplay(game_dir).LEFT_COMMUNITY_MODIFIER_TIMER or 7200
    if days ~= 0 and fx.add_timed_modifier then
        pcall(fx.add_timed_modifier, { kind = "country", id = player, modifier = "left_galactic_community", days = days })
    end
    for _, k in ipairs({ "members", "council" }) do
        local b = world.field(gc, k)
        if type(b) == "table" then
            world.remove_value(b, player)
        end
    end
    local em = world.field(gc, "emissaries")
    for _, l in ipairs(ids(em)) do
        local lo = world.object("leader", l)
        if lo and tonumber(world.field(lo, "country")) == player then
            world.remove_value(em, l)
        end
    end
    local run = {}
    local ok, eval = pcall(require, "simscript.eval")
    local okev, events = pcall(require, "simscript.events")
    if ok and okev then
        local okr, err = pcall(events.on_action, "on_remove_community_member", eval.S("country", player), eval.new_ctx(eval.S("country", player), eval.S("country", player)))
        run[#run + 1] = "on_remove_community_member" .. (okr and "" or (" failed: " .. tostring(err)))
    end
    return serialize({ ok = true, done = true, note = "left, -" .. leave .. " influence; ran " .. table.concat(run, ", ") })
end

return Mb
