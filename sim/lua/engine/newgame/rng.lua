-- engine/newgame/rng.lua : the random number streams of game creation.
--
-- The galaxy generator does not draw from the game's global generator (CRandom::_Random, the
-- platform's RUST.rand). CGameState::GenerateNewGalaxy (GOG 0x263b00) draws one value v from it,
-- and the generator gets a stream of its own, a local CNoiseRandom { position, seed } (docs/newgame.md,
-- "Seeding"):
--
--   seed      = noise31(noise32(v, 0x5EA6_BA9F), 0)        -- CGalaxyGenerator::Generate's argument
--   generator = { position = noise32(seed, 0x5EA6_BA9F), seed = 0 }
--
-- (0x5EA6BA9F = 1587985055.) Every draw of the generator is inlined in the game: the "Squirrel3"
-- noise with a fourth round (sim/src/rng.rs), the position advanced by one, the low 31 bits kept; a
-- value in [0, n) is the remainder (`cdq; idiv`).
--
--   local rng = require("engine.newgame.rng")
--   local r = rng.stream(seed)        -- the generator's stream for a galaxy seed
--   r:int()                           -- [0, 2^31)
--   r:below(n)                        -- [0, n)
--   r:range(lo, hi)                   -- [lo, hi], as the game draws `{ min max }`
--   r:fixed_range(lo, hi)             -- a CFixedPoint interval (numbers), see below
--   rng.global()                      -- the platform's global stream (RUST.rand), same methods

local bit = require("bit")

local rng = {}

local TWO32 = 4294967296
local N1, N2, N3, N4 = 0xB5297A4D, 0x68E31DA4, 0x1B56C4E9, 0x92D68CA2
rng.SEED_SALT = 1587985055

-- a * b mod 2^32, exact in doubles (16-bit halves)
local function mul32(a, b)
    local alo, ahi = a % 65536, (a - a % 65536) / 65536
    local blo, bhi = b % 65536, (b - b % 65536) / 65536
    local mid = (alo * bhi + ahi * blo) % 65536
    return (mid * 65536 + alo * blo) % TWO32
end
rng.mul32 = mul32

local function u32(x)
    return x % TWO32
end

-- the noise of draw `position` for `seed`, all 32 bits (both uint32)
function rng.noise32(position, seed)
    local x = u32(seed + mul32(u32(position), N1))
    x = u32(bit.bxor(x, bit.rshift(x, 8)))
    x = u32(x + N2)
    x = u32(bit.bxor(x, bit.lshift(x, 8)))
    x = mul32(x, N3)
    x = u32(bit.bxor(x, bit.rshift(x, 8)))
    x = mul32(x, N4)
    x = u32(bit.bxor(x, bit.rshift(x, 8)))
    return x
end

-- the value of a draw (CRandom::GetIntegerForMacro, the inlined draws): the low 31 bits
function rng.noise31(position, seed)
    return rng.noise32(position, seed) % 2147483648
end

local Stream = {}
Stream.__index = Stream

-- a CNoiseRandom { position, seed }
function rng.new(position, seed)
    return setmetatable({ position = u32(position), seed = u32(seed or 0), draws = 0 }, Stream)
end

-- the generator's stream for a galaxy seed (CGalaxyGenerator::Generate, 0x98be5f)
function rng.stream(seed)
    return rng.new(rng.noise32(u32(seed), rng.SEED_SALT), 0)
end

-- the seed GenerateNewGalaxy passes to Generate for a value v of the global stream (0x263b58)
function rng.seed_from_global(v)
    return rng.noise31(rng.noise32(u32(v), rng.SEED_SALT), 0)
end

function Stream:int()
    local v = rng.noise31(self.position, self.seed)
    self.position = u32(self.position + 1)
    self.draws = self.draws + 1
    return v
end

-- [0, n): the remainder of a draw (n > 0)
function Stream:below(n)
    if n <= 1 then
        -- the game still draws (`idiv` by 1)
        self:int()
        return 0
    end
    return self:int() % n
end

-- [lo, hi] (integers): lo + draw % (hi - lo + 1)
function Stream:range(lo, hi)
    if hi < lo then
        lo, hi = hi, lo
    end
    return lo + self:below(hi - lo + 1)
end

-- a number in [lo, hi] at the fixed point's resolution (1/100000): the game draws CFixedPoint
-- intervals as lo + (draw % ((hi - lo) * 100000 + 1)) / 100000 [I]
function Stream:fixed_range(lo, hi)
    if hi < lo then
        lo, hi = hi, lo
    end
    local span = math.floor((hi - lo) * 100000 + 0.5)
    return lo + self:below(span + 1) / 100000
end

-- [0, 1) at the fixed point's resolution
function Stream:unit()
    return self:below(100000) / 100000
end

-- an index into weights (numbers >= 0): the game's weighted pick, a draw below the total
-- (in fixed point) walked down the list [I]
function Stream:weighted(weights)
    local total = 0
    for i = 1, #weights do
        total = total + math.max(0, math.floor((weights[i] or 0) * 100000 + 0.5))
    end
    if total <= 0 then
        return nil
    end
    local r = self:below(total)
    for i = 1, #weights do
        local w = math.max(0, math.floor((weights[i] or 0) * 100000 + 0.5))
        if r < w then
            return i
        end
        r = r - w
    end
    return #weights
end

-- the platform's global stream (CRandom::_Random through RUST.rand), with the same methods
local Global = setmetatable({}, { __index = Stream })
Global.__index = Global
function Global:int()
    self.draws = self.draws + 1
    return RUST.rand()
end
function rng.global()
    return setmetatable({ draws = 0 }, Global)
end

return rng
