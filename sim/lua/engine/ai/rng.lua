-- engine/ai/rng.lua : the AI's own random number generators (docs/ai.md section 1), one per AI
-- country, apart from the game's global CRandom:
--
-- - unsynced (CAICore::_Random): restarted at load with seed = position = the country's id (the
--   saved random_seed / random_count are applied only with the game's -loadrandomseed option);
-- - synced (_SyncedRandom): from the save (synced_random_seed, synced_random_count); not drawn by
--   anything ported yet.
--
-- A draw is the game's noise (RUST.noise, sim/src/rng.rs: Squirrel3 with a fourth round) of the
-- position, then the position + 1; the value is 31 bits.
--
--   local rng = require("engine.ai.rng")
--   rng.draw(country)                      -- the next value of the country's unsynced generator
--   rng.weighted(weights, r)               -- CAICore GetWeightedRandomInternal: an index

local rng = { draws = 0 }

local unsynced = {} -- country -> { seed, position }

local function gen(country)
    local g = unsynced[country]
    if g == nil then
        g = { seed = country % 4294967296, position = country % 4294967296 }
        unsynced[country] = g
    end
    return g
end

-- rng.draw(country) -> a value in [0, 2^31)
function rng.draw(country)
    local g = gen(country)
    local v = RUST.noise(g.position, g.seed)
    g.position = (g.position + 1) % 4294967296
    rng.draws = rng.draws + 1
    return v
end

function rng.position(country)
    return gen(country).position
end

-- rng.weighted(weights, r) -> index (1-based) or nil (GetWeightedRandomInternal, 0x1b4ad80): the
-- weights are the game's fp15 integers; total = the sum of the positive ones; none positive: the
-- fallback r % n; else the first index whose running sum exceeds r % total
function rng.weighted(weights, r)
    local n = #weights
    if n == 0 then
        return nil
    end
    local total = 0
    for i = 1, n do
        if weights[i] > 0 then
            total = total + weights[i]
        end
    end
    if total <= 0 then
        return r % n + 1
    end
    -- (with a total above 2^31 - 1 the game scales the target; not seen with technology weights)
    local target = r % total
    local sum = 0
    for i = 1, n do
        if weights[i] > 0 then
            sum = sum + weights[i]
            if sum > target then
                return i
            end
        end
    end
    return n
end

-- a CFixedPoint value as the game's fp15 integer (48.15 fixed point), truncated
function rng.fp15(x)
    local i = math.floor(x)
    return i * 32768 + math.floor((x - i) * 32768)
end

return rng
