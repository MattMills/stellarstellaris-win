-- engine.reload end to end: a test mod's files rewritten during the run, then reload.scan()
-- (tools/reload_test.sh makes the mod, enables it through STELLAR_MODS_DIR and runs this with
-- RELOAD_MOD; the mod's files are written by setup and by this script)
local M = assert(os.getenv("RELOAD_MOD"))
local defs = require("engine.defs")
local db = require("simscript.db")
local eval = require("simscript.eval")
local loc = require("engine.localisation")
local reload = require("engine.reload")
local pdxscript = require("pdxscript")
local world = require("engine.world")

local function write(rel, text)
    local f = assert(io.open(M .. "/" .. rel, "wb"))
    f:write(text)
    f:close()
end
local out, fails = {}, 0
local function check(name, got, want)
    local ok = got == want
    if not ok then fails = fails + 1 end
    out[#out + 1] = string.format("%s %s: %s%s", ok and "ok  " or "FAIL", name, tostring(got), ok and "" or (" (want " .. tostring(want) .. ")"))
end
local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then return e.value.text end
    end
end

loc.load(os.getenv("STELLARIS_DIR"), "english")
local country = world.all("country")[1]
local ctx = eval.new_ctx(eval.S("country", country))
local st = pdxscript.parse("reload_st = yes", "test")
local sv = pdxscript.parse("value = value:reload_sv", "test")

-- before
local tech = defs.get("common/technology", "tech_reload_a")
check("tech a before", tech and field(tech.block, "cost"), "10")
check("tech b before", defs.get("common/technology", "tech_reload_b") ~= nil, true)
for _ = 1, 3 do eval.trigger(st, ctx) end
check("scripted trigger before (compiled)", eval.trigger(st, ctx), true)
for _ = 1, 3 do eval.value(sv[1].value, ctx, sv[1]) end
check("script value before", eval.value(sv[1].value, ctx, sv[1]), 5)
local b = defs.get("common/buildings", "building_reload")
check("inline script before", b and field(b.block, "reload_inline_field"), "one")
check("event before", db.events["reload_test.1"] and (db.events["reload_test.1"].hidden or false), false)
check("localisation before", loc.texts.RELOAD_KEY, "one")
check("variable before", db.globalvars.reload_var, "1")

-- the files rewritten: a changed, b removed, c added; the scripted trigger false; the inline script,
-- the event, the text and the variable changed
write("common/technology/zz_reload.txt", "tech_reload_a = { area = physics tier = 1 cost = 20 }\ntech_reload_c = { area = physics tier = 1 cost = 30 }\n")
write("common/scripted_triggers/zz_reload.txt", "reload_st = { always = no }\n")
write("common/script_values/zz_reload.txt", "reload_sv = { base = 7 }\n")
write("common/inline_scripts/zz/reload_inline.txt", "reload_inline_field = two\n")
write("events/zz_reload.txt", "namespace = reload_test\ncountry_event = { id = reload_test.1 is_triggered_only = yes hide_window = yes }\n")
write("localisation/english/zz_reload_l_english.yml", "\239\187\191l_english:\n RELOAD_KEY:0 \"two\"\n")
write("common/scripted_variables/zz_reload.txt", "@reload_var = 2\n")

local r = reload.scan()
out[#out + 1] = reload.summary(r)

-- after
local tech2 = defs.get("common/technology", "tech_reload_a")
check("tech a after", tech2 and field(tech2.block, "cost"), "20")
check("tech a kept its table", tech2 == tech, true)
check("tech b removed", defs.get("common/technology", "tech_reload_b"), nil)
check("tech c added", defs.get("common/technology", "tech_reload_c") ~= nil, true)
check("scripted trigger after", eval.trigger(st, ctx), false)
check("script value after", eval.value(sv[1].value, ctx, sv[1]), 7)
local b2 = defs.get("common/buildings", "building_reload")
check("inline script after", b2 and field(b2.block, "reload_inline_field"), "two")
check("event after", db.events["reload_test.1"] and db.events["reload_test.1"].hidden, true)
check("event in the list once", (function()
    local n = 0
    for _, ev in ipairs(db.event_list) do if ev.id == "reload_test.1" then n = n + 1 end end
    return n
end)(), 1)
check("localisation after", loc.texts.RELOAD_KEY, "two")
check("variable after", db.globalvars.reload_var, "2")
-- nothing changed: nothing reloaded
check("second scan", reload.scan(), nil)
return "RELOADTEST " .. (fails == 0 and "all passed" or (fails .. " failed")) .. "\n" .. table.concat(out, "\n")
