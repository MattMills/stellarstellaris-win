-- engine/newgame/fixed.lua : the game's fixed point arithmetic as the galaxy generator uses it
-- (CFixedPoint: int64, 1.0 = 100000), exact in Lua numbers for the magnitudes of game creation
-- (products below 2^53). GOG 4.5.2:
--
-- - fixmul(a, b): trunc(a * b / 100000), rounding toward zero (the fast path of operator*; the
--   slow path for |a| or |b| > 3037000499 gives the same value for these magnitudes);
-- - fixdiv(a, b): trunc(a * 100000 / b);
-- - sin / cos: fixed_int64::sin (0x1b43e30) / cos (0x1b43ee0): the angle reduced to [0, pi/2]
--   with pi = 3.14159 (2 pi = 6.28319), then _sinx (0x1b43c60): x - x^3/6 + x^5/120, each term
--   truncated, the powers built with fixmul;
-- - u(r): CNoiseRandom::GetInt64 (0x1b50900) % 100000, a fraction in [0, 1) (two positions of the
--   stream: (draw31 << 32 | hash32) % 100000).

local rng = require("engine.newgame.rng")

local fixed = {}

local ONE = 100000
fixed.ONE = ONE

local function trunc(v)
    if v >= 0 then
        return math.floor(v)
    end
    return -math.floor(-v)
end
fixed.trunc = trunc

-- trunc(n / d) for integers n, d (d > 0), exact
local function idiv(n, d)
    local neg = n < 0
    if neg then
        n = -n
    end
    local q = math.floor(n / d)
    if q * d > n then
        q = q - 1
    elseif (q + 1) * d <= n then
        q = q + 1
    end
    if neg then
        return -q
    end
    return q
end
fixed.idiv = idiv

function fixed.mul(a, b)
    return idiv(a * b, ONE)
end

function fixed.div(a, b)
    if b < 0 then
        return idiv(-a * ONE, -b)
    end
    return idiv(a * ONE, b)
end

-- a number -> raw fixed (rounded as the game's reader does: to the nearest 1/100000 [I])
function fixed.from(v)
    return math.floor(v * ONE + 0.5)
end

function fixed.to(raw)
    return raw / ONE
end

local mul = fixed.mul

local function sinx(x)
    local sum, p, fact, sign = 0, x, 1, 1
    for n = 2, 6, 2 do
        sum = sum + sign * idiv(p, fact)
        p = mul(x, mul(x, p))
        sign = -sign
        fact = fact * (n + 1) * n
    end
    return sum
end
fixed.sinx = sinx

local TWO_PI, PI, HALF_PI = 628319, 314159, 157080

function fixed.sin(a)
    local t = a % TWO_PI
    local neg = false
    if t > PI then
        t = t - PI
        neg = true
    end
    if t > HALF_PI then
        t = 314160 - t
    end
    local r = sinx(t)
    if neg then
        return -r
    end
    return r
end

function fixed.cos(a)
    return fixed.sin(a + HALF_PI)
end

-- CNoiseRandom::GetInt64 % 100000: hi = the 31-bit draw at position p, lo = all 32 bits at p + 1
local TWO32_MOD = 4294967296 % ONE
function fixed.u(r)
    local hi = rng.noise31(r.position, r.seed)
    local lo = rng.noise32((r.position + 1) % 4294967296, r.seed)
    r.position = (r.position + 2) % 4294967296
    r.draws = r.draws + 2
    return ((hi % ONE) * TWO32_MOD + lo % ONE) % ONE
end

-- clamp to [-500, 500] (raw)
function fixed.clamp500(v)
    if v < -50000000 then
        return -50000000
    elseif v > 50000000 then
        return 50000000
    end
    return v
end

-- CCelestialDistance::IsLessThan (0x996550) for a difference (dx, dy) against a distance m (raw):
-- closer than 1.0 on both axes is "near": the difference is scaled by 100 and compared with
-- (100 m)^2 when m < 10, and is always closer when m >= 10
function fixed.closer(dx, dy, m, near_threshold)
    near_threshold = near_threshold or ONE
    local near = math.abs(dx) < near_threshold and math.abs(dy) < near_threshold
    if near then
        if m >= 10 * ONE then
            return true
        end
        dx, dy, m = dx * 100, dy * 100, m * 100
    end
    return mul(dx, dx) + mul(dy, dy) < mul(m, m)
end

return fixed
