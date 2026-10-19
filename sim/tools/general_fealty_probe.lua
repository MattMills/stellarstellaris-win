-- tools/general_fealty_probe.lua: remove_secret_fealty on a relation given the flag (STELLAR_LUA=tools/general_fealty_probe.lua,
-- run 0 <save>; no script effect sets the flag: the diplomatic actions do; docs/script_general.md)
local eval = require("simscript.eval")
local pdx = require("pdxscript")
local world = require("engine.world")
local D = require("engine.diplomacy")
local out = {}
local player = tonumber(world.field(world.blocks(world.meta.player)[1], "country"))
local other
local _, list = D.relations_of(player)
for _, r in ipairs(list) do local c = tonumber(world.field(r, "country")) if c and world.object("country", c) then other = c break end end
local r = D.relation(player, other)
world.set(r, "secret_fealty", "yes")
eval.state.global_targets.them = eval.S("country", other)
local ctx = eval.new_ctx(eval.S("country", player), nil, nil, "probe")
out[#out + 1] = "player " .. player .. " other " .. other
out[#out + 1] = "before: has_secret_fealty_with = " .. tostring(eval.trigger(pdx.parse("has_secret_fealty_with = event_target:them", "p"), ctx))
eval.effect(pdx.parse("remove_secret_fealty = event_target:them", "p"), ctx)
out[#out + 1] = "after remove_secret_fealty: has_secret_fealty_with = " .. tostring(eval.trigger(pdx.parse("has_secret_fealty_with = event_target:them", "p"), ctx))
  .. ", relation secret_fealty = " .. tostring(world.field(r, "secret_fealty"))
return table.concat(out, "\n")
