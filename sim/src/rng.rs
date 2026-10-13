//! The game's random number generator.
//!
//! `CRandom::_Random` (GOG 4.5.2 `0x310cb68`) is a `CNoiseRandom { uint32 position; uint32 seed; }`.
//! `CRandom::GetIntegerForMacro(file, line)` (`0x1a760a0`) is the only single-value draw (1,024 call
//! sites); `CRandom::GetIntegersForMacro` (`0x1a762d0`) draws several. Each draw hashes
//! `(position, seed)` with the "Squirrel3" noise function plus a fourth round, advances the
//! position by one, copies it to `CSystem::_nRandomCount`, and returns the low 31 bits.
//!
//! Draws are forbidden while `CRandom::_InForbiddenZone` is set (`CModifierNodeManager::Update`, the
//! parallel phases): the game reports them; here they panic, which makes an ordering bug loud.
//!
//! `DailyUpdate` draws [`DAILY_POOL_SIZE`] values serially (`0x25e6a0`) and hands them to the
//! parallel per-object updates (`TFunctorWithRandomValues<CShip/CFleet/CArmy/CLeader>`), which read
//! the pool instead of drawing.

/// Values drawn by `DailyUpdate` for the parallel phases.
pub const DAILY_POOL_SIZE: usize = 1000;

const NOISE1: u32 = 0xB529_7A4D; // the asm subtracts n * 0x4AD685B3, its negation
const NOISE2: u32 = 0x68E3_1DA4;
const NOISE3: u32 = 0x1B56_C4E9;
const NOISE4: u32 = 0x92D6_8CA2;

/// The value of draw number `position` for `seed` (31 bits).
pub fn noise(position: u32, seed: u32) -> u32 {
    let mut x = seed.wrapping_add(position.wrapping_mul(NOISE1));
    x ^= x >> 8;
    x = x.wrapping_add(NOISE2);
    x ^= x << 8;
    x = x.wrapping_mul(NOISE3);
    x ^= x >> 8;
    x = x.wrapping_mul(NOISE4);
    x ^= x >> 8;
    x & 0x7FFF_FFFF
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct NoiseRandom {
    /// Draws so far (`CNoiseRandom +0`, saved with the game).
    pub position: u32,
    /// `CNoiseRandom +4`, saved with the game, set by `CSetRandomSeed` in multiplayer.
    pub seed: u32,
    forbidden: bool,
}

impl NoiseRandom {
    pub fn new(seed: u32) -> NoiseRandom {
        NoiseRandom { position: 0, seed, forbidden: false }
    }

    /// `CRandom::GetIntegerForMacro`: a value in `[0, 2^31)`.
    pub fn next_int(&mut self) -> i32 {
        assert!(
            !self.forbidden,
            "random draw in a forbidden zone (modifier update or parallel phase) at position {}",
            self.position
        );
        let v = noise(self.position, self.seed);
        self.position = self.position.wrapping_add(1);
        v as i32
    }

    /// A value in `[0, n)`. How the game reduces a draw to a range was not traced; a modulo is
    /// the placeholder.
    pub fn next_below(&mut self, n: i32) -> i32 {
        assert!(n > 0);
        self.next_int() % n
    }

    /// `CRandom::GetIntegersForMacro` / the daily pool: `n` serial draws.
    pub fn draw_pool(&mut self, n: usize) -> Vec<i32> {
        (0..n).map(|_| self.next_int()).collect()
    }

    /// Sets `CRandom::_InForbiddenZone`; returns the previous value (to restore it).
    pub fn set_forbidden(&mut self, on: bool) -> bool {
        std::mem::replace(&mut self.forbidden, on)
    }

    pub fn is_forbidden(&self) -> bool {
        self.forbidden
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reference values from a literal transliteration of the instructions of
    /// `CRandom::GetIntegerForMacro` (GOG 4.5.2 `0x1a76109`-`0x1a7615e`: `imul eax, r8d,
    /// 1255572915; sub ecx, eax; ...; btr ebx, 31`), computed independently of this code.
    #[test]
    fn matches_the_disassembly() {
        let cases: [(u32, [u32; 5]); 4] = [
            (0, [1874735034, 2066160111, 649684609, 777651738, 220119898]),
            (1, [1425195803, 388003433, 1418269600, 1125234208, 2079876984]),
            (12345, [2017601429, 1365798095, 176878266, 269251726, 853369338]),
            (0xdeadbeef, [1766153525, 128418462, 1935674563, 827729312, 1281059853]),
        ];
        for (seed, values) in cases {
            for (pos, v) in values.iter().enumerate() {
                assert_eq!(noise(pos as u32, seed), *v, "seed {seed} position {pos}");
            }
        }
        assert_eq!(noise(1_000_000, 42), 1699477020);
    }

    #[test]
    fn draws_advance_the_position() {
        let mut r = NoiseRandom::new(12345);
        assert_eq!(r.next_int(), 2017601429);
        assert_eq!(r.next_int(), 1365798095);
        assert_eq!(r.position, 2);
        let pool = r.draw_pool(DAILY_POOL_SIZE);
        assert_eq!(pool.len(), DAILY_POOL_SIZE);
        assert_eq!(r.position, 2 + DAILY_POOL_SIZE as u32);
        assert!(pool.iter().all(|v| *v >= 0));
    }

    #[test]
    #[should_panic(expected = "forbidden zone")]
    fn forbidden_zone_panics() {
        let mut r = NoiseRandom::new(1);
        r.set_forbidden(true);
        r.next_int();
    }
}
