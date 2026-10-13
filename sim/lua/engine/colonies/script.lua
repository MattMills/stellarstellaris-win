-- engine/colonies/script.lua : what the game rules of the colonies' day ask of the script layer that it
-- does not answer yet (simscript/eval.lua), installed only while engine.colonies evaluates
-- (script.with(f)), on top of engine/pops/script.lua and engine/economy/script.lua. Each is a
-- candidate for the script layer:
--
-- - is_being_assimilated (a pop group, CPopGroupIsBeingAssimilatedTrigger::ActualEvaluate 0x1973320):
--   the citizenship type of the group's species rights (CPopGroup::GetSpeciesRights) has
--   `is_assimilation = yes` (the script layer answered yes for every group, which made
--   pop_group_generates_crime fail everywhere).

local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")

local script = { used = {} }

local function count(name)
    script.used[name] = (script.used[name] or 0) + 1
end

local function yes(e) return e.value.text ~= "no" end

local NONE = 4294967295

local function group_owner(gid)
    local g = world.object("pop_groups", gid)
    local cid = g and tonumber(world.field(g, "planet"))
    local pid = cid and world.colony_planet[cid]
    local p = pid and world.object("planet", pid)
    local o = p and tonumber(world.field(p, "owner"))
    if o == NONE then return nil end
    return o
end

local function group_species(gid)
    local key = world.field(world.object("pop_groups", gid), "key")
    return type(key) == "table" and tonumber(world.field(key, "species")) or nil
end

local trig = {}
trig.is_being_assimilated = function(e, ctx)
    local this = ctx.this
    if this.kind ~= "pop_group" then return false == yes(e) end
    local owner, sid = group_owner(this.id), group_species(this.id)
    local economy_script = require("engine.economy.script")
    local r = owner and sid and economy_script.rights and economy_script.rights(owner, sid)
    local citizenship = r and world.field(r, "citizenship")
    local d = citizenship and defs.get("common/species_rights/citizenship_types", citizenship)
    local assimilating = d ~= nil and defs.field(d.block, "is_assimilation") == "yes"
    return assimilating == yes(e)
end

local TRIG = eval.TRIG
script.orig = {}
local installed = 0

-- script.with(f, ...) -> f's results, with the pops', the economy's and these triggers in place
function script.with(f, ...)
    local inner = function(...)
        if installed > 0 then
            return f(...)
        end
        installed = installed + 1
        for k, g in pairs(trig) do
            script.orig[k] = TRIG[k]
            TRIG[k] = function(...) count(k) return g(...) end
        end
        local res = { pcall(f, ...) }
        for k in pairs(trig) do TRIG[k] = script.orig[k] end
        installed = installed - 1
        if not res[1] then
            error(res[2], 0)
        end
        return unpack(res, 2)
    end
    local ok, ps = pcall(require, "engine.pops.script")
    if ok and ps and ps.with then
        return ps.with(inner, ...)
    end
    return inner(...)
end

return script
