-- game.lua : the game state, and a hook in the main loop where scripts can use it (see
-- docs/main_loop.md).
--
-- CGameState::HandleTurnTick runs one tick of the game, on the main thread, inside
-- CSession::ProcessSynchronousCommands: where the game itself changes the game state, at the same
-- point on every multiplayer client. A day is 10 ticks: every tick runs MicroUpdate and the AI,
-- and the tick that starts a new day also moves the date and runs DailyUpdate, MonthlyUpdate and
-- YearlyUpdate. Once game.start() has hooked it, callbacks run around the ticks, with
-- g_AllowGlobalGameStateAccess open:
--
--   local game = require("stellar.game")
--   game.before_tick(function(gamestate, db) ... end)  -- before every tick
--   game.after_tick(function(gamestate, db) ... end)   -- after every tick
--   game.after_day(function(gamestate, db) ... end)    -- after the tick that started a new day:
--                                                      -- its daily, monthly and yearly updates are done
--
-- `gamestate` is the CGameState and `db` its CGameStateDatabase (addresses). The callbacks run on
-- the game's main thread, holding the Lua lock: the init thread (the heartbeat) waits for them, and
-- the game waits for them. In multiplayer, what they change stays in sync only if it is
-- deterministic. A callback that raises an error is logged and removed.

local resolve = require("stellar.resolve")
local util = require("stellar.util")
local hex = util.hex

local game = {}

-- CGameState in 4.5.2 (from the PDB)
game.layout = {
    db = 0x930,           -- CGameStateDatabase *_pDB
    current_date = 0xc0,  -- CGameDate _CurrentDate: int _nUniversalDate, in hours
}

-- The functions, found by their signatures (stellar.resolve; listed in functions.lua).
local FUNCTIONS = {
    "CGameState::HandleTurnTick",
    "CGameApplication::Update",
    "CInGameIdler::CheckTick",
}

-- Offsets (from 0) of the matches of a pattern ("c6 05 ?? ?? ?? ?? 01") in a string of bytes.
local function search(bytes, pattern)
    local want = {}
    for b in pattern:gmatch("%S+") do
        want[#want + 1] = b ~= "??" and tonumber(b, 16) or false
    end
    local matches = {}
    for i = 1, #bytes - #want + 1 do
        local j = 1
        while j <= #want and (not want[j] or bytes:byte(i + j - 1) == want[j]) do
            j = j + 1
        end
        if j > #want then
            matches[#matches + 1] = i - 1
        end
    end
    return matches
end

local function int32(bytes, offset)
    local b1, b2, b3, b4 = bytes:byte(offset + 1, offset + 4)
    local v = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
    return v >= 0x80000000 and v - 0x100000000 or v
end

-- game.locate(image, read) -> where | nil, message
--   image  an fnmatch image of the game
--   read   function(address, size) -> string | nil, message: reads the game's code (stellar.read)
-- where has the functions (handle_turn_tick, update, check_tick) and the globals (gate, which is
-- g_AllowGlobalGameStateAccess, allow_get_player, current_game_state).
function game.locate(image, read)
    local found = resolve.functions(image)
    local entries = {}
    for _, name in ipairs(FUNCTIONS) do
        if not found[name] then
            return nil, "fnmatch: " .. name .. " not found"
        end
        entries[name] = { address = found[name] }
    end
    local where = {
        handle_turn_tick = entries["CGameState::HandleTurnTick"].address,
        update = entries["CGameApplication::Update"].address,
        check_tick = entries["CInGameIdler::CheckTick"].address,
    }

    local function code(name)
        local f = image:function_at(entries[name].address)
        local bytes, message = read(f.address, f.end_address - f.address)
        if bytes == nil then
            error(name .. ": " .. tostring(message), 0)
        end
        return f.address, bytes
    end
    local ok, message = pcall(function()
        -- CGameApplication::Update opens the game state: g_AllowGetPlayer = 0, then
        -- g_AllowGlobalGameStateAccess = 1 (two `mov byte ptr [rip+x], imm8`), and soon after
        -- compares g_CurrentGameState with 0 (`cmp qword ptr [rip+x], reg`)
        local at, bytes = code("CGameApplication::Update")
        local m = search(bytes, "c6 05 ?? ?? ?? ?? 00 c6 05 ?? ?? ?? ?? 01")
        if #m ~= 1 then
            error(string.format("CGameApplication::Update: %d matches for the gate", #m), 0)
        end
        where.allow_get_player = at + m[1] + 7 + int32(bytes, m[1] + 2)
        where.gate = at + m[1] + 14 + int32(bytes, m[1] + 9)
        for i = m[1] + 14, #bytes - 7 do
            local rex, op, modrm = bytes:byte(i + 1, i + 3)
            if (rex == 0x48 or rex == 0x4c) and op == 0x39 and modrm < 0x40 and modrm % 8 == 5 then
                where.current_game_state = at + i + 7 + int32(bytes, i + 3)
                break
            end
        end
        if where.current_game_state == nil then
            error("CGameApplication::Update: no cmp with g_CurrentGameState", 0)
        end

        -- CInGameIdler::CheckTick opens the same gate
        at, bytes = code("CInGameIdler::CheckTick")
        local confirmed = false
        for _, o in ipairs(search(bytes, "c6 05 ?? ?? ?? ?? 01")) do
            confirmed = confirmed or at + o + 7 + int32(bytes, o + 2) == where.gate
        end
        if not confirmed then
            error("CInGameIdler::CheckTick does not open the gate CGameApplication::Update opens", 0)
        end
    end)
    if not ok then
        return nil, message
    end
    return where
end

-- The callbacks
local callbacks = { before = {}, after = {}, day = {} }

function game.before_tick(fn)
    table.insert(callbacks.before, fn)
end

function game.after_tick(fn)
    table.insert(callbacks.after, fn)
end

function game.after_day(fn)
    table.insert(callbacks.day, fn)
end

local ffi = require("ffi")

local function pointer_at(address)
    return tonumber(ffi.cast("uintptr_t *", address)[0])
end

-- game.db(gamestate) -> the CGameStateDatabase
function game.db(gamestate)
    return pointer_at(gamestate + game.layout.db)
end

local function hours(gamestate)
    return ffi.cast("int32_t *", gamestate + game.layout.current_date)[0]
end

-- game.date(gamestate) -> year, month, day. The date is in hours, from 5000 years (of 365 days)
-- before year 0; Stellaris counts 360-day years of twelve 30-day months (CStellarisDate::GetYear).
function game.date(gamestate)
    local days = math.floor((hours(gamestate) - 43800000) / 24)
    return math.floor(days / 360), math.floor(days % 360 / 30) + 1, days % 30 + 1
end

function game.date_string(gamestate)
    return string.format("%d.%02d.%02d", game.date(gamestate))
end

local function call_all(list, what, gamestate, db)
    local i = 1
    while i <= #list do
        local fn = list[i]
        local ok, message = xpcall(function() return fn(gamestate, db) end, debug.traceback)
        if ok then
            i = i + 1
        else
            game.log(string.format("game: %s callback failed and is removed: %s", what, tostring(message)))
            table.remove(list, i)
        end
    end
end

-- Called by the hook (stellar.turn_tick) before and after each tick.
local date_before
local function turn_tick(phase, gamestate, gate_was_open)
    if not gate_was_open and not game.reported_closed_gate then
        game.reported_closed_gate = true
        game.log(string.format("game: the gate was closed %s a tick (%s): the hook opened it", phase, game.date_string(gamestate)))
    end
    local db = game.db(gamestate)
    if phase == "before" then
        date_before = hours(gamestate)
        call_all(callbacks.before, "before-tick", gamestate, db)
    else
        call_all(callbacks.after, "after-tick", gamestate, db)
        if hours(gamestate) ~= date_before then
            call_all(callbacks.day, "after-day", gamestate, db)
        end
    end
end

-- game.start(image [, log]) -> where | nil, message: locates the functions and globals and hooks
-- the turn tick. In the game only.
function game.start(image, log)
    local stellar = require("stellar")
    game.log = log or stellar.log
    if game.where then
        return game.where
    end
    local t0 = util.now()
    local where, message = game.locate(image, stellar.read)
    if where == nil then
        game.log("game: cannot hook the turn tick: " .. message)
        return nil, message
    end
    game.log(string.format("game: CGameState::HandleTurnTick %s, CGameApplication::Update %s, CInGameIdler::CheckTick %s (%.2fs)",
        hex(where.handle_turn_tick), hex(where.update), hex(where.check_tick), util.now() - t0))
    game.log(string.format("game: g_AllowGlobalGameStateAccess %s, g_AllowGetPlayer %s, g_CurrentGameState %s",
        hex(where.gate), hex(where.allow_get_player), hex(where.current_game_state)))
    stellar.turn_tick = turn_tick
    local ok
    ok, message = stellar.hook_turn_tick(where.handle_turn_tick, where.gate)
    if not ok then
        stellar.turn_tick = nil
        game.log("game: cannot hook the turn tick: " .. message)
        return nil, message
    end
    game.where = where
    game.log("game: turn tick hooked")
    return where
end

-- game.current() -> the CGameState (g_CurrentGameState), or nil: outside the turn tick, reading it
-- races the main thread.
function game.current()
    if game.where then
        local gamestate = pointer_at(game.where.current_game_state)
        return gamestate ~= 0 and gamestate or nil
    end
end

game.log = print

return game
