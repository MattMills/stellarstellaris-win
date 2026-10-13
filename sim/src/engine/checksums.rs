//! State checksums.
//!
//! Stands in for `NOosChecksums::CalcChecksums` (`0x912370`, 131 slots of `uint64`, checked by
//! `NOosChecksums::MakeSyncCheck` (`0x914540`) at the start of every tick in multiplayer), which
//! hashes the RNG seed and draw count (`CSystem::_nSeed`, `_nRandomCount`), the object databases,
//! country stockpiles, pop groups, construction queues, fleet paths and positions, ship health and
//! flags. Here one FNV-1a hash over the same kinds of state the skeleton has.

use crate::state::{GameState, Resource};

struct Fnv(u64);

impl Fnv {
    fn new() -> Fnv {
        Fnv(0xcbf2_9ce4_8422_2325)
    }
    fn bytes(&mut self, b: &[u8]) {
        for x in b {
            self.0 ^= *x as u64;
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    fn u64(&mut self, v: u64) {
        self.bytes(&v.to_le_bytes());
    }
    fn i64(&mut self, v: i64) {
        self.bytes(&v.to_le_bytes());
    }
    fn str(&mut self, s: &str) {
        self.u64(s.len() as u64);
        self.bytes(s.as_bytes());
    }
}

pub fn checksum(st: &GameState) -> u64 {
    let mut h = Fnv::new();
    h.u64(st.rng.seed as u64);
    h.u64(st.rng.position as u64);
    h.i64(st.date.0 as i64);
    h.u64(st.tick_count as u64);
    let w = &st.world;
    for (id, c) in &w.countries {
        h.u64(*id as u64);
        h.u64(c.alive as u64);
        for r in Resource::ALL {
            h.i64(c.stockpile.get(r).raw());
        }
        for t in &c.techs {
            h.str(t);
        }
        for (area, slot) in &c.research {
            h.u64(*area as u64);
            h.str(slot.tech.as_deref().unwrap_or(""));
            h.i64(slot.progress.raw());
        }
    }
    for (id, c) in &w.colonies {
        h.u64(*id as u64);
        h.u64(c.owner as u64);
        for b in &c.buildings {
            h.str(b);
        }
        for q in &c.construction {
            h.str(&q.building);
            h.i64(q.days_left as i64);
        }
    }
    for (id, p) in &w.pop_groups {
        h.u64(*id as u64);
        h.str(&p.species);
        h.i64(p.size);
    }
    for (id, l) in &w.leaders {
        h.u64(*id as u64);
        h.u64(l.alive as u64);
        h.i64(l.age_days as i64);
    }
    for (id, f) in &w.fleets {
        h.u64(*id as u64);
        h.u64(f.system as u64);
        h.i64(f.progress.raw());
    }
    h.0
}
