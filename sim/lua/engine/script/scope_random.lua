-- engine/script/scope_random.lua : the random state every event scope carries (CEventScope +0x68
-- position, +0x6c seed: a CNoiseRandom; the save writes it as `random = { <seed> <position> }`).
-- The script's own draws (random, random_list, random_* iterators, a delayed event's random days,
-- the scopes of an event fired by an effect) come from it, never from the game's synchronized
-- generator (GOG 4.5.2, docs/script_creation.md "Scope random"):
--
--   H(x)          noise32(x, 0x5EA6BA9F): CEventScope::Init(x), the position of a scope made from x
--   new(x)        { pos = H(x), seed = 0 } (CEventScope(int), ctor 0x3912e0 -> Init)
--   default()     new(0) (the default ctor 0x391210 calls Init(0))
--   draw(r)       noise32(pos, seed) & 0x7FFFFFFF, pos + 1 (the inlined draw of CRandomEffect,
--                 CRandomListEffect::SRandomListImplDelegate::GetRandom, CFireEventEffect, ...)
--   int64(r)      CNoiseRandom::GetInt64: ((noise(p) & 0x7FFFFFFF) << 32) + noise(p + 1), p + 2
--   copy(r)       a scope made from another (CEventScope::Copy, CEventTarget::GetScope) starts
--                 from its state; its own draws do not advance the other's

local nrng = require("engine.newgame.rng")
local noise32 = nrng.noise32

local R = {}

local TWO32 = 4294967296
local SALT = 1587985055

local function u32(x)
    return x % TWO32
end

local function H(x)
    return noise32(u32(x), SALT)
end
R.H = H

function R.new(x)
    return { pos = H(x), seed = 0 }
end

function R.default()
    return { pos = H(0), seed = 0 }
end

-- a state written in a save: `random = { <seed> <position> }` (CEventScope::WriteMembers writes
-- +0x6c then +0x68)
function R.from_save(seed, pos)
    return { pos = u32(tonumber(pos) or 0), seed = u32(tonumber(seed) or 0) }
end

function R.draw(r)
    local v = noise32(r.pos, r.seed) % 2147483648
    r.pos = u32(r.pos + 1)
    return v
end

-- the value the next draw would give, without drawing (CLockedRandomListEffect reads the position
-- itself; this is the generator's next value, for tests)
function R.peek(r)
    return noise32(r.pos, r.seed) % 2147483648
end

-- GetInt64() % m, exact in doubles (the 63-bit value itself is not)
function R.int64_mod(r, m)
    local a = noise32(r.pos, r.seed) % 2147483648
    local b = noise32(u32(r.pos + 1), r.seed)
    r.pos = u32(r.pos + 2)
    return ((a % m) * (TWO32 % m) + b) % m
end

function R.copy(r)
    return { pos = r.pos, seed = r.seed }
end

-- the position as the game's int32 (cdq; idiv: a position at or above 2^31 is negative)
function R.signed_pos(r)
    return r.pos >= 2147483648 and r.pos - TWO32 or r.pos
end

return R
