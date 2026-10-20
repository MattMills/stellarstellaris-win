//! The map labels (interface/mapicons.gui; docs/windows/mapicons.md): the galaxy's star labels
//! (`star_mapicon`, CGalacticObjectMapIcon) and a system's fleet, station and planet labels
//! (`fleet_map_icon`, CFleetMapIcon; `planet_map_icon`, CPlanetMapIcon), bound to the save. The
//! world's facts come from `lua/render/windows/mapicons.lua` (read with the galaxy); the game's
//! rules for an observer (what it sees, which icon and frame) are applied here; the labels are
//! laid out by render.gui and drawn by scene::add_labels.

use std::collections::{HashMap, HashSet};

use stellar_sim::mlua::{self, Table};

use crate::app::{si_number, App, HoverTarget, MapView};
use crate::gui::{self, GuiItem};
use crate::math::V3;
use crate::scene::{self, Pickable};
use crate::system;

const MAPICONS: &str = "interface/mapicons.gui";

/// NCamera.GALAXY_SHOW_STARNAME_ZOOM (800) and GALAXY_SHOW_FLEETS_ZOOM (2300), the game's world:
/// map units are half of it (GALAXY_SPACE_SCALE_MULT 2).
pub const STARNAME_ZOOM: f32 = 400.0;
pub const FLEETS_ZOOM: f32 = 1150.0;

/// GetShipClassIconFrameFromSize's table by EShipClass (4.5.2 Linux 0x317e000) [V]: the frame of
/// GFX_ship_class_small for military, constructor, colonizer, science, transport, mining station,
/// research station, military station, habitat station, observation station, starbase, military
/// special, gravity snare, entropy conduit.
pub const SHIP_CLASS_FRAME: [u32; 14] = [3, 2, 14, 1, 15, 7, 9, 1, 6, 13, 8, 28, 1, 62];

/// GetShipClassIconFrameFromSize [V]: the ship size's ship_class_icon_frame when set; else a
/// military station 27, a mobile starbase 31; else the class's (SHIP_CLASS_FRAME).
pub fn ship_class_frame(size_frame: Option<u32>, class: u8, mobile_starbase: bool) -> u32 {
    match size_frame {
        Some(n) if n > 0 => n,
        _ if class == 7 => 27,
        _ if mobile_starbase => 31,
        _ => SHIP_CLASS_FRAME.get(class as usize).copied().unwrap_or(3),
    }
}

/// CFleet::GetFleetIconType's military tiers (NInterface.FLEET_ICON_POWER_TIERS: no defines file
/// sets it; the empty array's storage reads 343.02, .. as the tiers) [I]: a military fleet is
/// tier 1 up to the first, 7 past the last.
const POWER_TIERS: [f32; 5] = [343.022, 343.023, 343.023, 343.028, 343.028];

#[derive(Clone, Debug, Default)]
pub struct Starbase {
    pub level: String,
    pub size: String,
    pub owner: Option<u32>,
    /// its level's display_map_icon
    pub map_icon: bool,
    /// its size's icon_frame (GFX_starbase_ship_size_small)
    pub frame: u32,
}

#[derive(Clone, Debug, Default)]
pub struct FleetInfo {
    pub id: u32,
    pub owner: Option<u32>,
    /// EShipClass
    pub class: u8,
    pub power: f32,
    pub ftl: bool,
    pub station: bool,
    /// a station's size's ship_class_icon_frame
    pub icon_frame: Option<u32>,
}

#[derive(Clone, Debug, Default)]
pub struct Deposit {
    pub resource: String,
    pub amount: f32,
    /// the country whose station collects it
    pub collector: Option<u32>,
}

#[derive(Clone, Debug, Default)]
pub struct PlanetDeposits {
    pub id: u32,
    pub owner: Option<u32>,
    pub controller: Option<u32>,
    pub colony: bool,
    pub deposits: Vec<Deposit>,
}

#[derive(Clone, Debug, Default)]
pub struct SystemIcons {
    pub owner: Option<u32>,
    /// 1 an empire's capital, 2 a sector's, 0 neither
    pub capital: u8,
    /// CGalacticObject::CalcShouldDisplayShieldOnMap: a colony or a starbase level with
    /// display_empire_shield
    pub shield: bool,
    /// its starbases list names none that exists (the guardians' and enclaves' systems)
    pub null_starbase: bool,
    pub starbase: Option<Starbase>,
    pub fleets: Vec<FleetInfo>,
    pub planets: Vec<PlanetDeposits>,
    /// a first contact of the player's in progress there
    pub contact: bool,
}

/// What the labels show, from the world (render.windows.mapicons).
#[derive(Clone, Debug, Default)]
pub struct Data {
    /// common/strategic_resources in the game's order
    pub resources: Vec<String>,
    /// the countries whose type's faction is hostile (common/country_types)
    pub hostile: HashSet<u32>,
    /// the countries of an enclave type (enclave, mindwarden_enclave, enclave_mercenary)
    pub enclaves: HashSet<u32>,
    /// the planets the player has surveyed (surveyed_deposit_holders)
    pub player_surveyed: HashSet<u32>,
    /// the countries the player has communications with
    pub player_communications: Vec<u32>,
    pub systems: HashMap<u32, SystemIcons>,
    /// each fleet's EShipClass, and a station's size's ship_class_icon_frame
    pub fleet_class: HashMap<u32, u8>,
    pub fleet_frame: HashMap<u32, u32>,
}

fn country(v: i64) -> Option<u32> {
    (v >= 0).then_some(v as u32)
}

/// The Lua table render.windows.mapicons made (none: an empty one).
pub fn read(t: Option<Table>) -> mlua::Result<Data> {
    let mut d = Data::default();
    let Some(t) = t else { return Ok(d) };
    if let Some(r) = t.get::<Option<Table>>("resources")? {
        d.resources = r.sequence_values::<String>().collect::<mlua::Result<_>>()?;
    }
    if let Some(c) = t.get::<Option<Table>>("classes")? {
        for p in c.pairs::<u32, Table>() {
            let (id, v) = p?;
            if v.get::<Option<bool>>("hostile")?.unwrap_or(false) {
                d.hostile.insert(id);
            }
            if v.get::<Option<String>>("kind")?.is_some_and(|k| k.contains("enclave")) {
                d.enclaves.insert(id);
            }
        }
    }
    if let Some(c) = t.get::<Option<Table>>("player_communications")? {
        d.player_communications = c.sequence_values::<u32>().collect::<mlua::Result<_>>()?;
    }
    if let Some(s) = t.get::<Option<Table>>("player_surveyed")? {
        for p in s.pairs::<i64, bool>() {
            let (id, _) = p?;
            if id >= 0 {
                d.player_surveyed.insert(id as u32);
            }
        }
    }
    for s in t.get::<Table>("systems")?.sequence_values::<Table>() {
        let s = s?;
        let mut sys = SystemIcons {
            owner: country(s.get::<Option<i64>>("owner")?.unwrap_or(-1)),
            capital: s.get::<Option<u8>>("capital")?.unwrap_or(0),
            shield: s.get::<Option<bool>>("shield")?.unwrap_or(false),
            null_starbase: s.get::<Option<bool>>("null_starbase")?.unwrap_or(false),
            contact: s.get::<Option<bool>>("contact")?.unwrap_or(false),
            ..Default::default()
        };
        if let Some(b) = s.get::<Option<Table>>("starbase")? {
            sys.starbase = Some(Starbase {
                level: b.get("level")?,
                size: b.get("size")?,
                owner: country(b.get::<Option<i64>>("owner")?.unwrap_or(-1)),
                map_icon: b.get::<Option<bool>>("map_icon")?.unwrap_or(true),
                frame: b.get::<Option<i64>>("frame")?.unwrap_or(0).max(0) as u32,
            });
        }
        for f in s.get::<Table>("fleets")?.sequence_values::<Table>() {
            let f = f?;
            let info = FleetInfo {
                id: f.get("id")?,
                owner: country(f.get::<Option<i64>>("owner")?.unwrap_or(-1)),
                class: f.get::<Option<u8>>("class")?.unwrap_or(0),
                power: f.get::<Option<f32>>("power")?.unwrap_or(0.0),
                ftl: f.get::<Option<bool>>("ftl")?.unwrap_or(false),
                station: f.get::<Option<bool>>("station")?.unwrap_or(false),
                icon_frame: f.get::<Option<u32>>("icon_frame")?,
            };
            d.fleet_class.insert(info.id, info.class);
            if let Some(n) = info.icon_frame {
                d.fleet_frame.insert(info.id, n);
            }
            sys.fleets.push(info);
        }
        for p in s.get::<Table>("planets")?.sequence_values::<Table>() {
            let p = p?;
            let mut deposits = Vec::new();
            for e in p.get::<Table>("deposits")?.sequence_values::<Table>() {
                let e = e?;
                deposits.push(Deposit { resource: e.get("resource")?, amount: e.get("amount")?, collector: country(e.get::<Option<i64>>("collector")?.unwrap_or(-1)) });
            }
            sys.planets.push(PlanetDeposits {
                id: p.get("id")?,
                owner: country(p.get::<Option<i64>>("owner")?.unwrap_or(-1)),
                controller: country(p.get::<Option<i64>>("controller")?.unwrap_or(-1)),
                colony: p.get::<Option<bool>>("colony")?.unwrap_or(false), deposits });
        }
        d.systems.insert(s.get("id")?, sys);
    }
    Ok(d)
}

/// Who looks at the map: the player's country, or none when observing (OnExecute_Observe: the
/// local human has no country), and whom the player has communications with.
pub struct Observer<'a> {
    pub country: Option<u32>,
    pub communications: Option<&'a [u32]>,
}

impl Observer<'_> {
    /// NUtil::HasPlayerCommunicationsWith / CCountry::HasCommunications [I]: itself, the
    /// countries it has communications with; an observer has none (its fleets' icons are "?"),
    /// yet its labels show capitals (the game's observe frames).
    fn has_communications(&self, other: Option<u32>) -> bool {
        match (self.country, other) {
            (Some(me), Some(o)) => {
                me == o
                    || match self.communications {
                        Some(c) => c.contains(&o),
                        None => true,
                    }
            }
            _ => false,
        }
    }

    /// CFleet::GetFleetRelationType [V]: 0 its own, 3 hostile (CCountry::IsHostileCached: the
    /// owner's faction hostile [I]; wars not read), 2 allied (not read), 1 the others; an observer
    /// sees every fleet as 1 (its frames); a country without communications is hostile [I: the
    /// frames: an uncontacted empire's fleet red]
    fn relation(&self, owner: Option<u32>, data: &Data) -> u32 {
        match self.country {
            None => 1,
            Some(me) if owner == Some(me) => 0,
            Some(_) if owner.is_some_and(|o| data.hostile.contains(&o)) || !self.has_communications(owner) => 3,
            Some(_) => 1,
        }
    }
}

/// CFleet::GetFleetIconType [V]: 0 (unknown: "?") without communications with its owner; a
/// military fleet's tier by its power (1..7), science 8, constructor 9, transport 10, colonizer
/// 11, military special 13, entropy conduit 15, else 0.
fn fleet_icon_type(observer: &Observer, f: &FleetInfo) -> u32 {
    if !observer.has_communications(f.owner) {
        return 0;
    }
    match f.class {
        0 => {
            let n = POWER_TIERS.iter().take_while(|&&t| f.power > t).count() as u32;
            if n >= 5 {
                7
            } else {
                n + 1
            }
        }
        1 => 9,
        2 => 11,
        3 => 8,
        4 => 10,
        11 => 13,
        13 => 15,
        _ => 0,
    }
}

/// A star_fleet_entry: the presence icon's frame (GFX_fleet_presence_icons, CFleet::
/// GetFleetIconFrame: 1 + relation, + 4 in FTL) and the type overlay's
/// (GFX_fleet_presence_overlay_icons, GetFleetTypeIconFrame: 1 + icon type x 4 + relation), the
/// overlay hidden for a gravity snare.
struct FleetEntry {
    key: u32,
    frame: u32,
    type_frame: u32,
    show_type: bool,
}

/// CGalacticObjectMapIcon::UpdateSystemFleets [V]: the fleets of the classes the map shows
/// (military, constructor, colonizer, science, transport, military special, gravity snare,
/// entropy conduit), mobile (no stations), that the observer sees, one entry per relation and
/// icon type, in that order (relation major).
fn fleet_entries(observer: &Observer, data: &Data, sys: &SystemIcons, sees: bool) -> Vec<FleetEntry> {
    let mut out: Vec<FleetEntry> = Vec::new();
    for f in &sys.fleets {
        if f.station || !matches!(f.class, 0..=4 | 11..=13) {
            continue;
        }
        // CCountry::CanSee [I]: its own, else where the observer's sensors reach
        if observer.country.is_some() && f.owner != observer.country && !sees {
            continue;
        }
        let relation = observer.relation(f.owner, data);
        let kind = fleet_icon_type(observer, f);
        let key = relation * 16 + kind;
        if out.iter().any(|e| e.key == key) {
            continue;
        }
        out.push(FleetEntry {
            key,
            frame: 1 + relation + if f.ftl { 4 } else { 0 },
            type_frame: 1 + (kind * 4 | relation),
            show_type: f.class != 12,
        });
    }
    out.sort_by_key(|e| e.key);
    out
}

/// GetDiplomaticRelationColor [I]: the player's (CColor::SwitchHSVtoRGB of
/// RELATION_COLOR_PLAYER_HSV), others neutral, the selected one RELATION_COLOR_SELECTED_RGB.
fn relation_colour(observer: Option<u32>, owner: Option<u32>, selected: bool) -> [f32; 4] {
    if selected {
        [1.5, 1.1, 0.0, 1.0]
    } else if owner.is_some() && owner == observer {
        [0.0, 0.89, 0.61, 1.0]
    } else {
        [0.56, 0.56, 0.56, 1.0]
    }
}

/// NMapIcon::GetResourceAmountString [I]: whole numbers bare, else one decimal.
fn amount_string(v: f32) -> String {
    if (v - v.round()).abs() < 1e-3 {
        format!("{}", v.round() as i64)
    } else {
        format!("{v:.1}")
    }
}

/// An OverlappingElementsBox's places [I]: the items `w` wide, `spacing` apart, from the box's left
/// (format left) or centred in it; pressed together to overlap when they do not fit.
fn overlapping(n: usize, w: f32, spacing: f32, box_x: f32, box_w: f32, centre: bool) -> Vec<f32> {
    if n == 0 {
        return Vec::new();
    }
    let total = n as f32 * w + (n as f32 - 1.0) * spacing;
    let (step, total) = if total > box_w && n > 1 { ((box_w - w) / (n as f32 - 1.0), box_w) } else { (w + spacing, total) };
    // (COverlappingElementsBox::UpdateGraphics: the centring offset rounded half away from 0)
    let x0 = if centre { box_x + ((box_w - total) / 2.0).round() } else { box_x };
    (0..n).map(|k| x0 + k as f32 * step).collect()
}

/// Groups laid out items back to their labels by their path's prefix (the first `depth` parts).
fn assign(labels: &mut [scene::Label], index: &HashMap<String, usize>, items: Vec<GuiItem>, depth: usize) {
    for it in items {
        let path = match &it {
            GuiItem::Sprite { path, .. } | GuiItem::Text { path, .. } => path.clone(),
        };
        let base = path.split('/').take(depth).collect::<Vec<_>>().join("/");
        if let Some(&k) = index.get(&base) {
            labels[k].items.push(it);
        }
    }
}

impl App {
    /// The galaxy's star labels (`star_mapicon`, CGalacticObjectMapIcon::Update; docs/windows/
    /// mapicons.md) for the systems the observer knows: the name (UpdateName: grey where not fully
    /// surveyed) within GALAXY_SHOW_STARNAME_ZOOM; the owner's plate, flag and capital frame
    /// (UpdateOwner); the uncollected deposits (UpdateResources); the fleets' presence icons
    /// (UpdateSystemFleets) within GALAXY_SHOW_FLEETS_ZOOM; the starbase (UpdateStations); the
    /// player's first contacts.
    pub(crate) fn galaxy_labels(&mut self) -> Result<Vec<scene::Label>, String> {
        let (w, h) = self.size;
        let gd = self.game_dir.clone();
        let distance = self.camera.map_or(0.0, |c| c.distance);
        if distance > FLEETS_ZOOM {
            return Ok(Vec::new());
        }
        let names_on = distance <= STARNAME_ZOOM;
        self.map.as_mut().ok_or("no map")?.topbar(w, h)?;
        let map = self.map.as_mut().ok_or("no map")?;
        if !map.gui {
            return Ok(Vec::new());
        }
        let g = map.galaxy.clone();
        let data = g.mapicons.clone();
        let observer = Observer { country: if map.observe { None } else { Some(g.player) }, communications: g.communications.as_deref() };
        let known: Vec<usize> = match &g.terra_incognita {
            Some(ti) => ti.systems.iter().filter_map(|id| g.systems.iter().position(|s| s.id == *id)).collect(),
            None => (0..g.systems.len()).collect(),
        };
        // where the observer's sensors reach [I]: its systems and fleets, and one jump from them
        let sees: HashSet<u32> = match observer.country {
            None => HashSet::new(),
            Some(me) => {
                let mut base: HashSet<usize> = HashSet::new();
                for (i, s) in g.systems.iter().enumerate() {
                    let si = data.systems.get(&s.id);
                    if si.is_some_and(|x| x.owner == Some(me) || x.fleets.iter().any(|f| f.owner == Some(me))) {
                        base.insert(i);
                    }
                }
                let mut out: HashSet<u32> = base.iter().map(|&i| g.systems[i].id).collect();
                for &(a, b) in &g.lanes {
                    let (a, b) = (a as usize, b as usize);
                    if base.contains(&a) {
                        out.insert(g.systems[b].id);
                    }
                    if base.contains(&b) {
                        out.insert(g.systems[a].id);
                    }
                }
                out
            }
        };
        let names = gui::format_names(&self.runtime, &known.iter().map(|&i| &g.systems[i].name).collect::<Vec<_>>())?;
        let font = map.fonts.as_ref().and_then(|f| f.get("cg_16b"));
        let widths: Vec<f32> = names.iter().map(|n| font.map_or(8.0 * n.len() as f32, |f| f.width(n)).min(176.0)).collect();
        let empty = SystemIcons::default();
        let hovered = self.hovered_system();
        let mode = self.resource_mode();
        let mut specs = Vec::new();
        let mut anchors = Vec::new();
        let mut owners = Vec::new();
        // (the name's colour by label)
        let mut name_colour: HashMap<String, [f32; 3]> = HashMap::new();
        for ((&i, name), tw) in known.iter().zip(names).zip(widths) {
            let s = &g.systems[i];
            let si = data.systems.get(&s.id).unwrap_or(&empty);
            let prefix = format!("/label/system/{}", s.id);
            let p = format!("{prefix}/star_mapicon");
            let mut spec = gui::WindowSpec::new(MAPICONS, "star_mapicon");
            spec.parent = Some([0.0, 0.0, 0.0, 0.0]);
            let mut only: Vec<String> = Vec::new();
            let sel = self.selected == Some(Pickable::System(i));
            // half the name's width in whole pixels (CInstantTextBox::GetActualRequiredSize / 2)
            let half = ((tw as i32) / 2) as f32;
            let owner_country = si.owner.and_then(|o| g.countries.iter().position(|c| c.id == o));
            if names_on {
                only.push("name".into());
                spec.text.push((format!("{p}/name"), name));
                // UpdateName: white where the observer has fully surveyed the system, grey (0.5)
                // where not (restricted systems' reds not read) [V]
                let surveyed = fully_surveyed(&observer, &data, si);
                name_colour.insert(prefix.clone(), if surveyed { [1.0; 3] } else { [0.5; 3] });
                // UpdateOwner [V]: where the system shows its controller's shield (SetUpData: a
                // colony or a starbase level with display_empire_shield,
                // CalcShouldDisplayShieldOnMap) a plate fitted to the name (text + its height), the
                // flag at its left (star_mapicon_icon_offset[_capital] less half the name), a
                // capital's bigger plate, flag and decoration (frame 1 an empire's, 2 a sector's)
                // where the player has communications with the owner
                // (NUtil::HasPlayerCommunicationsWith: the player's, observing too); the flag
                // drawn for those only [I: the observe frames]
                // (a system whose starbases list names none that exists and with a military or
                // observation station, a guardian's or an
                // enclave's: a plate in MAP_ICON_COLOR_INACTIVE, no flag [I: the observe frames])
                let guarded = si.null_starbase && si.fleets.iter().any(|f| f.station && matches!(f.class, 7 | 9));
                if (si.owner.is_some() && si.shield) || guarded {
                    let known_owner = si.owner == Some(g.player) || si.owner.is_some_and(|o| data.player_communications.contains(&o));
                    let capital = if known_owner { si.capital } else { 0 };
                    let c = if si.owner.is_none() && !sel { [0.22, 0.22, 0.22, 1.0] } else { relation_colour(observer.country, si.owner, sel) };
                    let (bg, flag, bh, off) = if capital > 0 { ("name_bg_capital", "star_owner_capital", 22.0, (-40.0, 3.0)) } else { ("name_bg", "star_owner", 18.0, (-37.0, 7.0)) };
                    only.push(bg.into());
                    if known_owner {
                        only.push(flag.into());
                    }
                    spec.positions.push((format!("{p}/{bg}"), (-(half + bh / 2.0), if capital > 0 { 12.0 } else { 14.0 })));
                    spec.sizes.push((format!("{p}/{bg}"), (tw.trunc() + bh, bh)));
                    let fx = off.0 - half;
                    spec.positions.push((format!("{p}/{flag}"), (fx, off.1)));
                    if capital > 0 {
                        only.push("flag_capital_decoration".into());
                        spec.positions.push((format!("{p}/flag_capital_decoration"), (fx - 3.0, off.1 - 1.0)));
                        spec.frames.push((format!("{p}/flag_capital_decoration"), if capital == 1 { 1 } else { 2 }));
                    }
                    for n in [bg, flag] {
                        spec.tints.push((format!("{p}/{n}"), c));
                    }
                    spec.actions.push((format!("{p}/{bg}"), format!("map:slide:{i}")));
                }
            }
            // the hover marker (CGalacticObjectMapIcon::UpdateHoverIndicator [V]: hover_indicator,
            // GFX_map_icon_system_enter at (-35, -23), the hexagon and the eye about the star,
            // shown while the system is hovered; the game's frames: at the star, not its name)
            // [I: the sprite's variants by the selected fleets' orders (system_enter_cant,
            // system_goto_cant_has_intel, the jump drives') and idler+0xe88 not done]
            if hovered == Some(i) {
                only.push("hover_indicator".into());
            }
            spec.only = Some(only);
            spec.prefix = Some(prefix.clone());
            specs.push(spec);
            anchors.push(V3(s.x, s.height * 0.5, s.y));
            owners.push(owner_country);
            // the starbase (UpdateStations, CGalacticObjectMapIconStarbaseItem::UpdateWithData
            // [V]: its level's display_map_icon or a colony of its owner in the system, its size's
            // icon_frame above 0; starbase_icon_entry in `stations` at star_mapicon_stations_offset
            // right of the name)
            if names_on {
                let mut stations = 0;
                let shown = |sb: &&Starbase| sb.frame > 0 && (sb.map_icon || si.planets.iter().any(|pl| pl.colony && pl.owner == sb.owner));
                if let Some(sb) = si.starbase.as_ref().filter(shown) {
                    let mut e = gui::WindowSpec::new(MAPICONS, "starbase_icon_entry");
                    let ep = format!("{prefix}/station0");
                    e.parent = Some([5.0 + half, 7.0, 0.0, 0.0]);
                    e.frames.push((format!("{ep}/starbase_icon_entry/type"), sb.frame));
                    e.tints.push((format!("{ep}/starbase_icon_entry/type_bg"), relation_colour(observer.country, sb.owner, false)));
                    e.prefix = Some(ep);
                    specs.push(e);
                    stations += 1;
                }
                // the station fleets the map shows (ShouldShowIconForFleet [V]: military and
                // observation stations; station_icon_entry, the type its size's
                // ship_class_icon_frame, else the class's), 28 apart
                for f in si.fleets.iter().filter(|f| f.station && matches!(f.class, 7 | 9)) {
                    let mut e = gui::WindowSpec::new(MAPICONS, "station_icon_entry");
                    let ep = format!("{prefix}/station{stations}");
                    e.parent = Some([5.0 + half + 28.0 * stations as f32, 7.0, 0.0, 0.0]);
                    // (CFleet::GetIconFrame: a station of a country type with one flag [I: the
                    // enclaves'] 21, the enclave frame)
                    let frame = if f.owner.is_some_and(|o| data.enclaves.contains(&o)) { 21 } else { ship_class_frame(f.icon_frame, f.class, false) };
                    e.frames.push((format!("{ep}/station_icon_entry/type"), frame));
                    e.tints.push((format!("{ep}/station_icon_entry/type_bg"), relation_colour(observer.country, f.owner, false)));
                    e.prefix = Some(ep);
                    specs.push(e);
                    stations += 1;
                }
            }
            // the fleets' presence (`fleets`: star_fleet_entry, from (10, -15), 1 apart)
            let entries = fleet_entries(&observer, &data, si, sees.contains(&s.id));
            let xs = overlapping(entries.len(), 22.0, 1.0, 10.0, 176.0, false);
            for (k, (e, x)) in entries.iter().zip(xs).enumerate() {
                let mut f = gui::WindowSpec::new(MAPICONS, "star_fleet_entry");
                let ep = format!("{prefix}/fleet{k}");
                f.parent = Some([x, -15.0, 0.0, 0.0]);
                f.frames.push((format!("{ep}/star_fleet_entry/fleet"), e.frame));
                if e.show_type {
                    f.frames.push((format!("{ep}/star_fleet_entry/fleet_type"), e.type_frame));
                } else {
                    f.hide.push("fleet_type".into());
                }
                f.prefix = Some(ep);
                specs.push(f);
            }
            // the first contacts (`contacts` from (10, -31): contact_item, its button at (-25, -10))
            if si.contact && observer.country.is_some() {
                let mut c = gui::WindowSpec::new(MAPICONS, "contact_item");
                let ep = format!("{prefix}/contact0");
                c.parent = Some([10.0, -31.0, 0.0, 0.0]);
                c.prefix = Some(ep);
                specs.push(c);
            }
            // the deposits (UpdateResourcesThreaded, UpdateResources: `resources`, from (-88, 35),
            // 176 wide, 8 apart, centred; resource_icon_item), within the name's zoom [V]
            if names_on {
                let rows = resource_rows(&observer, &data, si, mode == ResourceMode::Details || hovered == Some(i), mode == ResourceMode::Hidden);
                // (a resource_icon_item counts 10 wide here: the frames step 18 with spacing 8 [I])
                let xs = overlapping(rows.len(), 10.0, 8.0, -88.0, 176.0, true);
                for (k, ((res, text), x)) in rows.iter().zip(xs).enumerate() {
                    let mut r = gui::WindowSpec::new(MAPICONS, "resource_icon_item");
                    let rp = format!("{prefix}/res{k}");
                    r.parent = Some([x, 35.0, 0.0, 0.0]);
                    r.sprites.push((format!("{rp}/resource_icon_item/icon"), format!("GFX_resource_{}", res.trim_end_matches("_research"))));
                    r.text.push((format!("{rp}/resource_icon_item/num"), text.clone()));
                    r.prefix = Some(rp);
                    specs.push(r);
                }
            }
        }
        let layout = gui::layout_specs(&self.runtime, w, h, &specs)?;
        let mut labels: Vec<scene::Label> = anchors.iter().map(|&a| scene::Label { anchor: a, drop: 0.0, items: Vec::new(), bounds: None, sort: 0 }).collect();
        let mut index: HashMap<String, usize> = HashMap::new();
        for &i in &known {
            index.insert(format!("/label/system/{}", g.systems[i].id), index.len());
        }
        let mut items = layout.items;
        for it in items.iter_mut() {
            if let GuiItem::Text { path, spans, .. } = it {
                let base = path.split('/').take(4).collect::<Vec<_>>().join("/");
                if path.ends_with("/star_mapicon/name") {
                    if let Some(c) = name_colour.get(&base) {
                        for (_, sc) in spans.iter_mut() {
                            *sc = [sc[0] * c[0], sc[1] * c[1], sc[2] * c[2]];
                        }
                    }
                }
            }
        }
        assign(&mut labels, &index, items, 4);
        let map = self.map.as_mut().unwrap();
        for (l, o) in labels.iter_mut().zip(owners) {
            map.flags(&mut l.items, o);
        }
        let all: Vec<GuiItem> = labels.iter().flat_map(|l| l.items.iter().cloned()).collect();
        gui::fonts(&self.runtime, &gd, &all, map.fonts.get_or_insert_with(HashMap::new))?;
        Ok(labels)
    }

    /// The system view's map labels (mapicons.gui; docs/windows/mapicons.md): each fleet's and
    /// station's `fleet_map_icon` (CFleetMapIcon::Update), each planet's `planet_map_icon` with
    /// an owner or deposits (CPlanetMapIcon::Update), in the relation colour
    /// (GetDiplomaticRelationColor: the player's, else neutral; the selected one gold).
    pub(crate) fn system_labels(&mut self) -> Result<Vec<scene::Label>, String> {
        if self.view == MapView::Galaxy && self.mode3d {
            return self.galaxy_labels();
        }
        let MapView::System(si) = self.view else { return Ok(Vec::new()) };
        let (w, h) = self.size;
        let gd = self.game_dir.clone();
        // the fonts (the name's width) come with the top bar
        self.map.as_mut().ok_or("no map")?.topbar(w, h)?;
        let map = self.map.as_mut().ok_or("no map")?;
        if !map.gui {
            return Ok(Vec::new());
        }
        let g = map.galaxy.clone();
        let data = map.system_data(g.systems[si].id)?;
        let player = map.player_country();
        let selected = self.selected;
        // CColor::SwitchHSVtoRGB of RELATION_COLOR_PLAYER_HSV and _NEUTRAL_HSV; _SELECTED_RGB
        let tint = |owner: Option<usize>, sel: bool| -> [f32; 4] {
            if sel {
                [1.5, 1.1, 0.0, 1.0]
            } else if owner.is_some() && owner == player {
                [0.0, 0.89, 0.61, 1.0]
            } else {
                [0.56, 0.56, 0.56, 1.0]
            }
        };
        let size = |name: &str| gui::sprite_size(&self.runtime, &self.cache, &gd, name).unwrap_or((32.0, 32.0));
        let mut specs = Vec::new();
        // (label index -> anchor, drop, bounds, sort, owner)
        let mut meta: Vec<(V3, f32, Option<[f32; 4]>, i64, Option<usize>)> = Vec::new();
        // the fleets, in the system's order of their ships
        let mut seen = std::collections::HashSet::new();
        for s in &data.ships {
            if !seen.insert(s.fleet) {
                continue;
            }
            let Some(f) = g.fleets.iter().find(|f| f.id == s.fleet) else { continue };
            let prefix = format!("/label/fleet/{}", f.id);
            let p = format!("{prefix}/fleet_map_icon");
            let mut spec = gui::WindowSpec::new(MAPICONS, "fleet_map_icon");
            spec.parent = Some([0.0, 0.0, 0.0, 0.0]);
            // (the shield bar hidden at 0: the military ones have shields, the others none [I];
            // the ship counters laid out below)
            for n in ["fleet_icon", "fleet_type", "cloaked_state", "has_ftl_magnet", "has_ftl_inhibitor", "ship_counters", "resources", "special_project"] {
                spec.hide.push(n.into());
            }
            // the shield bar: not on the orbital stations (mining, research, habitat, observation),
            // which have no shields [I: the frames' bars]
            let class = g.mapicons.fleet_class.get(&f.id).copied().unwrap_or(if f.station { 10 } else { 0 });
            if matches!(class, 5 | 6 | 8 | 9) {
                spec.hide.push("shield".into());
            }
            // the type icon (GFX_ship_class_small): GetShipClassIconFrameFromSize's frame by the
            // fleet's EShipClass [V] (the ship size's own ship_class_icon_frame not read)
            let frame = ship_class_frame(g.mapicons.fleet_frame.get(&f.id).copied(), class, false);
            spec.frames.push((format!("{p}/type"), frame));
            let sel = selected == Some(Pickable::Fleet(f.id));
            let c = tint(f.owner, sel);
            for n in ["bg", "flag", "type_bg"] {
                spec.tints.push((format!("{p}/{n}"), c));
            }
            spec.actions.push((format!("{p}/bg"), format!("select:fleet:{}", f.id)));
            let military = f.military_power > 0.0;
            if military {
                // CFleetMapIcon: MILITARY_POWER "£military_power£ $VALUE|*0$" (*1 with K from 1000)
                spec.text.push((format!("{p}/offensive_power"), format!("\u{a3}military_power\u{a3} {}", si_number(f.military_power.round()))));
            } else {
                spec.hide.push("offensive_power".into());
            }
            spec.prefix = Some(prefix.clone());
            specs.push(spec);
            // the ship counters (ship_counters: a ship_counter_entry per ship size of its military
            // ships, centred under the bar; GFX_ship_counter_<n> by the size [I])
            let c_tint = c;
            if military && !f.station {
                let mut counts: Vec<(u32, u32)> = Vec::new();
                for sh in data.ships.iter().filter(|x| x.fleet == f.id) {
                    let n = match sh.size.as_str() {
                        "corvette" => 4,
                        "destroyer" => 8,
                        "cruiser" => 16,
                        "battleship" => 32,
                        "titan" => 64,
                        "juggernaut" | "colossus" => 128,
                        _ => continue,
                    };
                    match counts.iter_mut().find(|c| c.0 == n) {
                        Some(c) => c.1 += 1,
                        None => counts.push((n, 1)),
                    }
                }
                let k = counts.len() as f32;
                for (j, (n, c)) in counts.iter().enumerate() {
                    let mut e = gui::WindowSpec::new(MAPICONS, "ship_counter_entry");
                    let ep = format!("{prefix}/res{j}");
                    e.parent = Some([-65.0 + 25.0 + 87.0 / 2.0 - k * 18.0 / 2.0 + j as f32 * 18.0, 8.0 + 24.0, 0.0, 0.0]);
                    e.sprites.push((format!("{ep}/ship_counter_entry/icon"), format!("GFX_ship_counter_{n}")));
                    e.text.push((format!("{ep}/ship_counter_entry/count"), c.to_string()));
                    e.tints.push((format!("{ep}/ship_counter_entry/icon"), c_tint));
                    e.prefix = Some(ep);
                    specs.push(e);
                }
            }
            // civilian fleets (not stations) take military_fleet_icon_size 108 x 48 less: 32
            let bounds = [-65.0, 8.0, 108.0, if military || f.station { 48.0 } else { 32.0 }];
            // (stations sort with the military: not flagged civilian [I], the frame's order)
            let sort = f.id as i64 + if military || f.station { 0x1_FFFF_FFFE } else { 0xFFFF_FFFF };
            meta.push((V3(s.x, 0.0, s.y), 0.0, Some(bounds), sort, f.owner));
        }
        // the planets with an owner or deposits; their names localised
        let shown: Vec<&system::Body> = data.bodies.iter().filter(|b| b.owner >= 0 || !b.deposits.is_empty()).collect();
        let names = gui::format_names(&self.runtime, &shown.iter().map(|b| &b.name).collect::<Vec<_>>())?;
        let widths: Vec<f32> = names.iter().map(|n| map.fonts.as_ref().and_then(|f| f.get("cg_16b")).map_or(8.0 * n.len() as f32, |f| f.width(n)).min(800.0)).collect();
        let flag_w = size("GFX_map_icon_flag").0;
        let cap_w = size("GFX_map_icon_flag_capital").0;
        for ((b, name), tw) in shown.iter().zip(names).zip(widths) {
            let owner = if b.owner >= 0 { g.countries.iter().position(|c| c.id as i64 == b.owner) } else { None };
            let capital = g.capital.is_some_and(|(p, _)| p == b.id);
            let prefix = format!("/label/planet/{}", b.id);
            let p = format!("{prefix}/planet_map_icon");
            let mut spec = gui::WindowSpec::new(MAPICONS, "planet_map_icon");
            spec.parent = Some([0.0, 0.0, 0.0, 0.0]);
            let mut only: Vec<String> = vec!["name".into()];
            let bg = if capital { "bg_capital" } else { "bg" };
            only.push(bg.into());
            // NMapIcon::AdjustNameBg [V]: the plate the name's width (whole pixels) +
            // planet_map_icon_bg[_capital]_size_offset (23) wide, centred
            let wi = tw as i32;
            spec.positions.push((format!("{p}/{bg}"), (-((wi + 23) / 2) as f32, 12.0)));
            spec.sizes.push((format!("{p}/{bg}"), ((wi + 23) as f32, 22.0)));
            // NMapIcon::AdjustFlagButton [V]: left of the name, half its width less the element's
            // own (a button's; an icon counts none [I: measured]) plus planet_map_icon_<name>_offset;
            // right of it (the type icons) half its width plus the offset
            let half = (wi / 2) as f32;
            let left = |ew: f32, ox: f32| -half - ew + ox;
            if owner.is_some() {
                if capital {
                    only.push("flag_capital".into());
                    only.push("flag_capital_decoration".into());
                    spec.positions.push((format!("{p}/flag_capital"), (left(cap_w, -12.0), 3.0)));
                    // the decoration about the flag [I]
                    spec.positions.push((format!("{p}/flag_capital_decoration"), (left(0.0, -55.0), 3.0)));
                    spec.frames.push((format!("{p}/flag_capital_decoration"), 1));
                } else {
                    only.push("flag".into());
                    spec.positions.push((format!("{p}/flag"), (left(flag_w, -14.0), 7.0)));
                }
            }
            if b.colony {
                for n in ["type", "type_bg", "type_bg2", "health"] {
                    only.push(n.into());
                }
                spec.positions.push((format!("{p}/type"), (half + 9.0, 8.0)));
                spec.positions.push((format!("{p}/type_bg2"), (half + 9.0, 8.0)));
                spec.positions.push((format!("{p}/type_bg"), (half + 5.0, 7.0)));
                spec.positions.push((format!("{p}/health"), (left(0.0, -17.0), 11.0)));
            }
            let sel = selected == Some(Pickable::Body(b.id));
            let c = tint(owner, sel);
            for n in ["bg", "bg_capital", "flag", "flag_capital", "type_bg"] {
                spec.tints.push((format!("{p}/{n}"), c));
            }
            spec.text.push((format!("{p}/name"), name.clone()));
            spec.actions.push((format!("{p}/{bg}"), format!("select:planet:{}", b.id)));
            // the type frame selects too (CPlanetMapIcon::OnReload: bg, bg_capital and type_bg
            // take the clicks; the flags none) [V]
            if b.colony {
                spec.actions.push((format!("{p}/type_bg"), format!("select:planet:{}", b.id)));
            }
            spec.only = Some(only);
            spec.prefix = Some(prefix.clone());
            specs.push(spec);
            // the deposits under the name: a resource_icon_item each, centred, the amount green
            let n = b.deposits.len() as f32;
            for (k, (res, amount)) in b.deposits.iter().enumerate() {
                let mut r = gui::WindowSpec::new(MAPICONS, "resource_icon_item");
                let rp = format!("{prefix}/res{k}");
                r.parent = Some([-n * 19.0 / 2.0 + k as f32 * 19.0 + 3.0, 37.0, 0.0, 0.0]);
                r.sprites.push((format!("{rp}/resource_icon_item/icon"), format!("GFX_resource_{}", res.trim_end_matches("_research"))));
                r.text.push((format!("{rp}/resource_icon_item/num"), format!("\u{a7}G{}\u{a7}!", amount.trunc() as i64)));
                r.prefix = Some(rp);
                specs.push(r);
            }
            // the label's place: under the planet by 0.6 of its size (PLANET_MAP_ICON_OFFSET)
            let radius = {
                let crate::Map { models, runtime, .. } = &mut *map;
                // the bounding sphere: half the largest extent
                models.model(runtime, &gd, &b.entity).map(|m| { let (lo, hi) = m.aabb; 0.5 * (hi[0] - lo[0]).max(hi[1] - lo[1]).max(hi[2] - lo[2]) * m.scale }).unwrap_or(1.0)
            };
            let drop = radius * system::entity_scale(b.size, b.class_scale, b.moon_of >= 0) / system::SYSTEM_SPACE_SCALE * 0.6;
            let hh = 22.0 + if b.deposits.is_empty() { 0.0 } else { 42.0 };
            meta.push((V3(b.x, system::PLANE_Y, b.y), drop, Some([-tw / 2.0, -hh / 2.0, tw, hh]), b.id as i64, owner));
        }
        let layout = gui::layout_specs(&self.runtime, w, h, &specs)?;
        // the items back to their labels (by their path's prefix)
        let mut labels: Vec<scene::Label> = Vec::new();
        let mut index: HashMap<String, usize> = HashMap::new();
        let mut k = 0;
        for s in &specs {
            let key = s.prefix.clone().unwrap_or_default();
            let base = key.split("/res").next().unwrap_or("").to_string();
            if !index.contains_key(&base) {
                let (anchor, drop, bounds, sort, _) = meta[k];
                k += 1;
                index.insert(base.clone(), labels.len());
                labels.push(scene::Label { anchor, drop, items: Vec::new(), bounds, sort });
            }
        }
        assign(&mut labels, &index, layout.items, 4);
        // the owners' flags
        let owners: Vec<Option<usize>> = meta.iter().map(|m| m.4).collect();
        let map = self.map.as_mut().unwrap();
        for (l, o) in labels.iter_mut().zip(owners) {
            map.flags(&mut l.items, o);
        }
        let all: Vec<GuiItem> = labels.iter().flat_map(|l| l.items.iter().cloned()).collect();
        gui::fonts(&self.runtime, &self.game_dir, &all, map.fonts.get_or_insert_with(HashMap::new))?;
        Ok(labels)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn box_selection_order() {
        // FilterSelectionList: the player's mobile fleets first, then the player's stations,
        // then the others' mobile fleets
        let mut v = vec![(selection_rank(false, true), 1), (selection_rank(true, false), 2), (selection_rank(true, true), 3)];
        v.sort_by_key(|x| x.0);
        assert_eq!(v.iter().map(|x| x.1).collect::<Vec<_>>(), vec![3, 2, 1]);
    }

    #[test]
    fn overlapping_boxes() {
        // three resources centred in the 176 wide box, 8 apart
        assert_eq!(overlapping(3, 10.0, 8.0, -88.0, 176.0, true), vec![-23.0, -5.0, 13.0]);
        // fleets from the left, 1 apart; pressed together when they do not fit
        assert_eq!(overlapping(2, 22.0, 1.0, 10.0, 176.0, false), vec![10.0, 33.0]);
        let xs = overlapping(10, 22.0, 1.0, 10.0, 176.0, false);
        assert_eq!(xs[0], 10.0);
        assert!((xs[9] + 22.0 - 186.0).abs() < 1e-3);
    }

    #[test]
    fn fleet_icons() {
        let data = Data { hostile: [7].into_iter().collect(), ..Default::default() };
        let player = Observer { country: Some(0), communications: Some(&[]) };
        let observing = Observer { country: None, communications: None };
        let own = |class, power| FleetInfo { id: 1, owner: Some(0), class, power, ftl: false, station: false, icon_frame: None };
        // the player's: military tier 1, science 8, constructor 9 (the frame's order)
        assert_eq!(fleet_icon_type(&player, &own(0, 169.0)), 1);
        assert_eq!(fleet_icon_type(&player, &own(3, 0.0)), 8);
        assert_eq!(fleet_icon_type(&player, &own(1, 0.0)), 9);
        // a monster's (no communications): unknown, hostile
        let monster = FleetInfo { id: 2, owner: Some(7), class: 0, power: 50.0, ftl: false, station: false, icon_frame: None };
        assert_eq!(fleet_icon_type(&player, &monster), 0);
        assert_eq!(player.relation(monster.owner, &data), 3);
        // an observer: every fleet neutral and unknown
        assert_eq!(observing.relation(Some(0), &data), 1);
        assert_eq!(fleet_icon_type(&observing, &own(0, 169.0)), 0);
        let sys = SystemIcons { fleets: vec![own(0, 169.0), own(3, 0.0), own(1, 0.0), monster.clone()], ..Default::default() };
        let e = fleet_entries(&player, &data, &sys, true);
        assert_eq!(e.iter().map(|e| (e.frame, e.type_frame)).collect::<Vec<_>>(), vec![(1, 5), (1, 33), (1, 37), (4, 4)]);
        assert_eq!(fleet_entries(&observing, &data, &sys, false).len(), 1);
    }
}

/// A fleet's place on the map's selection: the player's mobile fleets first, then the player's,
/// then the mobile ones (CGameState::FilterSelectionList) [V].
fn selection_rank(owned: bool, mobile: bool) -> u8 {
    match (owned, mobile) {
        (true, true) => 0,
        (true, false) => 1,
        (false, true) => 2,
        (false, false) => 3,
    }
}

impl App {
    /// The map labels' actions (`map:...`; docs/windows/mapicons.md "Clicks"): `map:slide:I`, a
    /// star label's plate: the galaxy camera slides to system I (CGalacticObjectMapIcon::
    /// OnBGClicked -> CInGameIdler::SlideCameraToSystem, when the observer has intel there) [V];
    /// the system is not selected.
    pub(crate) fn map_act(&mut self, a: &str) -> Result<(), String> {
        let mut it = a.split(':').skip(1);
        match (it.next(), it.next()) {
            (Some("slide"), Some(i)) => {
                let i: usize = i.parse().map_err(|_| format!("bad action {a}"))?;
                let Some(at) = self.map.as_ref().and_then(|m| m.galaxy.systems.get(i)).map(|s| V3(s.x, s.height * 0.5, s.y)) else { return Ok(()) };
                if self.view == MapView::Galaxy {
                    if let Some(g) = self.goal_mut() {
                        g.target = at;
                    }
                    self.goal_moved();
                }
                self.log.push(format!("map: the camera to system {i}"));
            }
            _ => self.log.push(format!("{a}: not done yet")),
        }
        Ok(())
    }

    /// The left button dragged over the map and released (CInGameIdler::HandleInputEvent
    /// @0x1c8613f, 16 pixels squared from the press; CGameState::GetSelectablesForDragSelection):
    /// the fleets in the box, the player's mobile ones first (FilterSelectionList) [V]; the first
    /// of them selected, all of them the right click's (App::selected_fleets); none:
    /// the selection cleared.
    pub(crate) fn box_select(&mut self, x: f32, y: f32) -> Result<bool, String> {
        let Some((x0, y0)) = self.map_press.take() else { return Ok(false) };
        let (l, r, t, b) = (x0.min(x), x0.max(x), y0.min(y), y0.max(y));
        let inside: Vec<u32> = self
            .scene()?
            .picks
            .iter()
            .filter(|p| p.centre.0 >= l && p.centre.0 <= r && p.centre.1 >= t && p.centre.1 <= b)
            .filter_map(|p| match p.what {
                Pickable::Fleet(id) => Some(id),
                _ => None,
            })
            .collect();
        let Some(map) = self.map.as_ref() else { return Ok(false) };
        let g = &map.galaxy;
        let mut found: Vec<(u8, u32)> = Vec::new();
        for id in inside {
            if found.iter().any(|f| f.1 == id) {
                continue;
            }
            let Some(f) = g.fleets.iter().find(|f| f.id == id) else { continue };
            let owned = f.owner.map(|o| g.countries[o].id) == Some(g.player);
            found.push((selection_rank(owned, !f.station), id));
        }
        found.sort_by_key(|f| f.0);
        self.log.push(format!("box select {l},{t} {r},{b}: {} fleets", found.len()));
        self.select(found.first().map(|f| Pickable::Fleet(f.1)));
        // all of them selected for the right click's orders (rightclick.rs: App::selected_fleets)
        self.fleet.group = found.iter().map(|f| f.1).collect();
        Ok(true)
    }
}

impl App {
    /// A system's camera fitted again to the system's size once its data has come: the window
    /// loads the save behind the load screen and enters the capital's system before the
    /// simulation has sent its bodies (Map::system_data's stand-in, outer_radius 100), and the
    /// camera's zoom steps (ZOOM_STEPS_SYSTEM_PERCENTAGES of the outer radius) were those of the
    /// stand-in: the view about 3.7 x closer than the game's, every label and pick elsewhere.
    /// The zoom steps and the distance are scaled to the system's own radius; the angles and the
    /// target kept. Whether it changed.
    pub(crate) fn refit_system_camera(&mut self) -> bool {
        let MapView::System(i) = self.view else { return false };
        let Some(map) = self.map.as_ref() else { return false };
        let id = map.galaxy.systems.get(i).map(|s| s.id);
        let Some(size) = map.snapshot.as_ref().and_then(|s| s.system.as_ref()).filter(|(sid, _)| Some(*sid) == id).map(|(_, d)| d.outer_radius) else { return false };
        let Some(goal) = self.system_camera_goal else { return false };
        let Some(steps) = goal.zoom_steps else { return false };
        // the fitted size: the step at 100 % (ZOOM_STEPS_SYSTEM_PERCENTAGES[4] = 1.0)
        let fitted = steps[4];
        if size <= 0.0 || fitted <= 0.0 || (size / fitted - 1.0).abs() < 1e-3 {
            return false;
        }
        let k = size / fitted;
        for c in [self.system_camera.as_mut(), self.system_camera_goal.as_mut()].into_iter().flatten() {
            c.zoom_steps = Some(system::SYSTEM_ZOOM_STEPS.map(|p| p * size));
            c.distance *= k;
            c.max_distance = 3.0 * size;
            c.min_distance = 0.025 * size;
        }
        self.log.push(format!("system camera: fitted again to the system's radius {size} (was {fitted})"));
        self.relayout();
        true
    }
}

impl App {
    /// The galaxy's system under the cursor (CInGameIdler's hovered system, idler+0xaa4: the star
    /// the ray picks; not its name nor a label's part): its star label's hover marker.
    pub(crate) fn hovered_system(&self) -> Option<usize> {
        match (&self.hovered, self.view) {
            (Some((HoverTarget::Map(Pickable::System(i)), _)), MapView::Galaxy) => Some(*i),
            _ => None,
        }
    }
}

/// What the star labels' resources show (UpdateResourcesThreaded's flags [V]): the available
/// deposits (Normal), all of them (Details: CInGameIdler::IsMapFilterEnabled(1), the bottom bar's
/// details filter or Alt held; a hovered system's label too), none (Hidden: the filter's third
/// state, unless Alt is held).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum ResourceMode {
    Normal,
    Details,
    Hidden,
}

/// Whether the observer has surveyed a deposit holder (CCountry::_HasSurveyedDepositHolder [V]):
/// its owner's or its controller's, or in its surveyed_deposit_holders; all when observing.
fn surveyed(observer: &Observer, data: &Data, pl: &PlanetDeposits) -> bool {
    match observer.country {
        None => true,
        Some(me) => pl.owner == Some(me) || pl.controller == Some(me) || data.player_surveyed.contains(&pl.id),
    }
}

/// CCountry::HasFullySurveyedSystem [V]: the observer's own system, or every planet surveyed
/// [I: astral rifts not read; a country type needing no survey not read].
fn fully_surveyed(observer: &Observer, data: &Data, si: &SystemIcons) -> bool {
    match observer.country {
        None => true,
        Some(me) => si.owner == Some(me) || si.planets.iter().all(|pl| surveyed(observer, data, pl)),
    }
}

/// A star label's resources, in common/strategic_resources' order: each resource's icon and its
/// `num` text (CGalacticObjectMapIcon::UpdateResources [V]). CGalacticObject::
/// ListResourcesForMapmode sums the deposits of the surveyed planets that are not colonies into
/// three tables: not collected, collected by the observer's station, by another's. Normal: the
/// not collected sum in white (§W), where the observer may see it (NeedsBorderAccess: an unowned
/// system, its own, an owner without communications); a resource with nothing left out. Details:
/// the three sums on lines of their own, white, green (§G), yellow (§Y), each one above 0 [I:
/// the hindered deposits' §H not done]. Hidden: none.
pub(crate) fn resource_rows(observer: &Observer, data: &Data, si: &SystemIcons, details: bool, hidden: bool) -> Vec<(String, String)> {
    if hidden && !details {
        return Vec::new();
    }
    let access = match observer.country {
        None => true,
        Some(me) => si.owner.is_none() || si.owner == Some(me) || !observer.has_communications(si.owner),
    };
    // resource -> (not collected, the observer's, others')
    let mut sums: Vec<(String, [f32; 3])> = Vec::new();
    for pl in si.planets.iter().filter(|pl| !pl.colony && surveyed(observer, data, pl)) {
        for dep in &pl.deposits {
            let k = match (dep.collector, observer.country) {
                (None, _) => 0,
                (Some(c), Some(me)) if c == me => 1,
                (Some(_), None) => 1,
                (Some(_), _) => 2,
            };
            match sums.iter_mut().find(|x| x.0 == dep.resource) {
                Some(x) => x.1[k] += dep.amount,
                None => {
                    let mut v = [0.0; 3];
                    v[k] = dep.amount;
                    sums.push((dep.resource.clone(), v));
                }
            }
        }
    }
    sums.sort_by_key(|x| data.resources.iter().position(|r| *r == x.0).unwrap_or(usize::MAX));
    let mut out = Vec::new();
    for (res, v) in sums {
        if !details && v[0] <= 0.0 {
            continue;
        }
        let mut lines: Vec<String> = Vec::new();
        if (access || details) && v[0] > 0.0 {
            lines.push(format!("§W{}§!", amount_string(v[0])));
        }
        if details {
            for (amount, code) in [(v[1], 'G'), (v[2], 'Y')] {
                if amount > 0.0 {
                    lines.push(format!("§{code}{}§!", amount_string(amount)));
                }
            }
        }
        if !lines.is_empty() {
            out.push((res, lines.join("\n")));
        }
    }
    out
}

impl App {
    /// The star labels' resources mode (ResourceMode): the bottom bar's details filter
    /// (mainbars.rs: 0 normal, 1 details, 2 hidden), Alt held showing the details.
    pub(crate) fn resource_mode(&self) -> ResourceMode {
        let filter = self.bars.filters[crate::mainbars::FILTERS.iter().position(|f| *f == "details").unwrap_or(2)];
        if self.controls.mods().alt || filter == 1 {
            ResourceMode::Details
        } else if filter == 2 {
            ResourceMode::Hidden
        } else {
            ResourceMode::Normal
        }
    }
}
