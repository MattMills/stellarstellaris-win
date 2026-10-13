//! The game state of the subsystems the minimal simulation keeps (docs/simulation.md, section 5).
//!
//! The game keeps one `CGameStateDatabase` of object databases (`TPdxRefDatabase<CCountry>`,
//! `<CColony>`, `<CPopGroup>`, `<CLeader>`, `<CFleet>`, ...; docs/main_loop.md). Here each is a
//! `BTreeMap` by id: iteration is in id order, the deterministic stand-in for the game's database
//! order. Static data read from the script files (buildings, jobs, economic categories,
//! technologies) is in [`Defs`]; in the real setup the Lua layer reads it.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::date::Date;
use crate::fixed::Fixed;
use crate::rng::NoiseRandom;

pub type Id = u32;

/// The strategic resources the skeleton models (the game has 26, `CStrategicResourceDatabase`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Resource {
    #[default]
    Energy,
    Minerals,
    Food,
    Alloys,
    ConsumerGoods,
    Unity,
    Influence,
    Physics,
    Society,
    Engineering,
}

pub const NUM_RESOURCES: usize = 10;

impl Resource {
    pub const ALL: [Resource; NUM_RESOURCES] = [
        Resource::Energy,
        Resource::Minerals,
        Resource::Food,
        Resource::Alloys,
        Resource::ConsumerGoods,
        Resource::Unity,
        Resource::Influence,
        Resource::Physics,
        Resource::Society,
        Resource::Engineering,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Resource::Energy => "energy",
            Resource::Minerals => "minerals",
            Resource::Food => "food",
            Resource::Alloys => "alloys",
            Resource::ConsumerGoods => "consumer_goods",
            Resource::Unity => "unity",
            Resource::Influence => "influence",
            Resource::Physics => "physics_research",
            Resource::Society => "society_research",
            Resource::Engineering => "engineering_research",
        }
    }

    /// Research is not stockpiled: `CTechnologyStatus::DailyResearch` spends it daily.
    pub fn is_research(self) -> bool {
        matches!(self, Resource::Physics | Resource::Society | Resource::Engineering)
    }
}

/// A resource table (`CFixedResourceTable`: one `CFixedPoint` per resource).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Res(pub [Fixed; NUM_RESOURCES]);

impl Res {
    pub fn get(&self, r: Resource) -> Fixed {
        self.0[r as usize]
    }
    pub fn set(&mut self, r: Resource, v: Fixed) {
        self.0[r as usize] = v;
    }
    pub fn add(&mut self, r: Resource, v: Fixed) {
        self.0[r as usize] += v;
    }
    pub fn with(mut self, r: Resource, v: Fixed) -> Res {
        self.set(r, v);
        self
    }
    pub fn covers(&self, cost: &Res) -> bool {
        Resource::ALL.iter().all(|r| self.get(*r) >= cost.get(*r))
    }
    pub fn sub_all(&mut self, cost: &Res) {
        for r in Resource::ALL {
            self.add(r, -cost.get(r));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Static definitions (the databases the Lua layer reads from common/)

#[derive(Clone, Debug, Default)]
pub struct JobDef {
    /// `CEconomicCategory` of the job's resource table (e.g. `planet_miners`).
    pub category: String,
    pub produces: Res,
    pub upkeep: Res,
}

#[derive(Clone, Debug, Default)]
pub struct BuildingDef {
    pub cost: Res,
    pub build_days: i32,
    pub upkeep: Res,
    pub category: String,
    /// Job slots per building, in pops.
    pub jobs: Vec<(String, u32)>,
}

#[derive(Clone, Debug, Default)]
pub struct TechDef {
    pub area: Resource,
    pub cost: Fixed,
    pub prerequisites: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub struct Defs {
    pub jobs: BTreeMap<String, JobDef>,
    pub buildings: BTreeMap<String, BuildingDef>,
    pub techs: BTreeMap<String, TechDef>,
    /// Economic categories: name -> parent (`CEconomicCategory::_pParent`).
    pub categories: BTreeMap<String, Option<String>>,
}

impl Defs {
    /// The category and its ancestors, nearest first.
    pub fn category_chain(&self, category: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut cur = Some(category.to_string());
        while let Some(c) = cur {
            if out.contains(&c) {
                break; // a cycle in bad data
            }
            cur = self.categories.get(&c).cloned().flatten();
            out.push(c);
        }
        out
    }
}

// ---------------------------------------------------------------------------------------------
// Objects

#[derive(Clone, Debug, Default)]
pub struct ResearchSlot {
    pub tech: Option<String>,
    pub progress: Fixed,
}

#[derive(Clone, Debug, Default)]
pub struct Country {
    pub name: String,
    pub alive: bool,
    pub stockpile: Res,
    /// The budget's last month (`CCountryBudget::_LastMonth`): what the top bar shows and daily
    /// research spends.
    pub last_month_income: Res,
    pub research: BTreeMap<Resource, ResearchSlot>,
    pub techs: BTreeSet<String>,
    /// Edicts with their end date.
    pub edicts: BTreeMap<String, Date>,
    /// The capital colony (`capital_scope`).
    pub capital: Option<Id>,
    /// Engine properties script reads (`is_country_type`, `has_authority`, ...): name -> value.
    pub attrs: BTreeMap<String, String>,
    /// Engine sets script reads (`has_ethic`, `has_civic`, ...): name -> members.
    pub sets: BTreeMap<String, BTreeSet<String>>,
}

#[derive(Clone, Debug)]
pub struct Construction {
    pub building: String,
    pub days_left: i32,
}

#[derive(Clone, Debug, Default)]
pub struct Colony {
    pub owner: Id,
    pub name: String,
    pub buildings: Vec<String>,
    pub construction: VecDeque<Construction>,
    pub pop_groups: Vec<Id>,
    /// Filled job slots by job (`NPlanetJobs::UpdatePopJobs`), in pops.
    pub employed: BTreeMap<String, u32>,
    pub unemployed: u32,
    /// Monthly growth progress toward the next pop (`ApplyMonthlyAssembly`), in pops.
    pub growth_progress: Fixed,
    /// Engine properties (`is_planet_class`, `has_designation`, ...).
    pub attrs: BTreeMap<String, String>,
    pub sets: BTreeMap<String, BTreeSet<String>>,
}

/// Pop group sizes are in units of 1/100 pop (`POP_BULK_UNIT_SIZE` = 100).
pub const POP_UNIT: i64 = 100;

#[derive(Clone, Debug, Default)]
pub struct PopGroup {
    pub colony: Id,
    pub species: String,
    pub size: i64,
}

#[derive(Clone, Debug, Default)]
pub struct Leader {
    pub country: Id,
    pub age_days: i32,
    pub alive: bool,
    pub attrs: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Default)]
pub struct Fleet {
    pub owner: Id,
    pub system: Id,
    pub destination: Option<Id>,
    /// Progress of the current jump, 0 to 1.
    pub progress: Fixed,
    pub speed_per_tick: Fixed,
}

/// Modifier values per scope: what the planned Lua graph (docs/modifier_graph.md) owns. Here a
/// flat store of sources and a recomputed view (`colony` sees its owner's country values).
#[derive(Clone, Debug, Default)]
pub struct Modifiers {
    /// (scope, source, modifier type) -> (value, end date or none). The source is the static
    /// modifier (`add_modifier = { modifier = x }`) or the type itself for a bare value.
    pub sources: BTreeMap<(crate::script::Scope, String, String), (Fixed, Option<Date>)>,
    pub computed: BTreeMap<(crate::script::Scope, String), Fixed>,
    pub dirty: bool,
    pub recomputes: u32,
}

#[derive(Clone, Debug, Default)]
pub struct World {
    pub defs: Defs,
    pub countries: BTreeMap<Id, Country>,
    pub colonies: BTreeMap<Id, Colony>,
    pub pop_groups: BTreeMap<Id, PopGroup>,
    pub leaders: BTreeMap<Id, Leader>,
    pub fleets: BTreeMap<Id, Fleet>,
    pub modifiers: Modifiers,
    next_id: Id,
}

impl World {
    pub fn alloc_id(&mut self) -> Id {
        self.next_id += 1;
        self.next_id
    }

    pub fn add_country(&mut self, name: &str) -> Id {
        let id = self.alloc_id();
        self.countries.insert(id, Country { name: name.into(), alive: true, ..Default::default() });
        id
    }

    pub fn add_colony(&mut self, owner: Id, name: &str) -> Id {
        let id = self.alloc_id();
        self.colonies.insert(id, Colony { owner, name: name.into(), ..Default::default() });
        if let Some(c) = self.countries.get_mut(&owner) {
            if c.capital.is_none() {
                c.capital = Some(id);
            }
        }
        id
    }

    pub fn add_pop_group(&mut self, colony: Id, species: &str, size: i64) -> Id {
        let id = self.alloc_id();
        self.pop_groups.insert(id, PopGroup { colony, species: species.into(), size });
        if let Some(c) = self.colonies.get_mut(&colony) {
            c.pop_groups.push(id);
        }
        id
    }

    pub fn add_leader(&mut self, country: Id, age_days: i32) -> Id {
        let id = self.alloc_id();
        self.leaders.insert(id, Leader { country, age_days, alive: true, attrs: BTreeMap::new() });
        id
    }

    /// Whole pops on a colony.
    pub fn colony_pops(&self, colony: Id) -> u32 {
        let Some(c) = self.colonies.get(&colony) else { return 0 };
        let units: i64 = c.pop_groups.iter().filter_map(|p| self.pop_groups.get(p)).map(|p| p.size).sum();
        (units / POP_UNIT) as u32
    }

    /// A modifier's current value in a scope (possibly stale until the next recompute, like
    /// `GetModifier()`).
    pub fn modifier(&self, scope: crate::script::Scope, name: &str) -> Fixed {
        self.modifiers.computed.get(&(scope, name.to_string())).copied().unwrap_or(Fixed::ZERO)
    }
}

/// `CGameState`: the date, the tick counter, the synchronized RNG and the database.
#[derive(Clone, Debug)]
pub struct GameState {
    /// `_CurrentDate` (`+0xc0`).
    pub date: Date,
    /// `_nTickCount` (`+0x8`): 1-10 within a day.
    pub tick_count: u32,
    /// The month index and year cached on the last day tick (`+0x128`, `+0x118`).
    pub cached_month: i32,
    pub cached_year: i32,
    pub rng: NoiseRandom,
    pub world: World,
}

impl GameState {
    pub fn new(date: Date, seed: u32, world: World) -> GameState {
        GameState {
            date,
            tick_count: 0,
            cached_month: date.month_index(),
            cached_year: date.year(),
            rng: NoiseRandom::new(seed),
            world,
        }
    }
}

impl World {
    /// Whether a scope has a modifier from this source (`has_modifier`).
    pub fn has_modifier_source(&self, scope: crate::script::Scope, source: &str) -> bool {
        self.modifiers.sources.keys().any(|(s, src, _)| *s == scope && src == source)
    }
}
