//! The starbase window (interface/starbase_view.gui; `lua/render/windows/starbase.lua` lays it
//! out, `starbase_data.lua` reads the world; docs/windows/starbase.md): the starbases' values read
//! where the galaxy is read (the save's runtime or the simulation's thread) into a Lua chunk that
//! travels with the galaxy (`Galaxy::starbases`), handed to the front end's runtime before the
//! windows are laid out, with the window's own state (the tab chosen); the window's clicks. The
//! megastructure window (megastructure_view.gui, `lua/render/windows/megastructure.lua`) is opened
//! by its own state, the renderer having no megastructure selection.

use stellar_sim::Runtime;

use crate::app::App;
use crate::galaxy::Galaxy;
use crate::gui::GuiItem;
use crate::scene::Pickable;
use crate::Map;

/// What the window keeps between layouts (CStarbaseView +0x408: the tab, kept from one starbase
/// to the next).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    /// 0 Command, 1 Defenses, 2 Shipyard, 3 Army Hub (EStarbaseViewTabType)
    pub tab: u32,
    /// the megastructure whose window is open (its save id)
    pub megastructure: Option<i64>,
}

/// The starbases' chunk (render.windows.starbase_data.extract) in the world's runtime; empty when
/// it cannot be read (the window then shows its frame and name).
pub fn extract(runtime: &Runtime, game_dir: &str) -> String {
    let code = format!("return require('render.windows.starbase_data').extract({:?})", game_dir.replace('\\', "/"));
    match runtime.lua.load(code).eval::<String>() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("render.windows.starbase_data: {e}");
            String::new()
        }
    }
}

/// The front end's globals the layout reads: the chunk, the state, the player, whether something is
/// selected (its window replaces a megastructure's).
pub fn prepare(runtime: &Runtime, galaxy: &Galaxy, state: &State, selected: bool) -> Result<(), String> {
    let set = || -> stellar_sim::mlua::Result<()> {
        let lua = &runtime.lua;
        lua.globals().set("RENDER_STARBASE_DATA", galaxy.starbases.as_str())?;
        let t = lua.create_table()?;
        t.set("tab", state.tab)?;
        t.set("player", galaxy.player)?;
        t.set("megastructure", state.megastructure)?;
        t.set("selected", selected)?;
        // the countries the player knows (communications; none: all), for the flags shown
        if let Some(c) = &galaxy.communications {
            let k = lua.create_table()?;
            for id in c.iter().chain(std::iter::once(&galaxy.player)) {
                k.set(*id, true)?;
            }
            t.set("known", k)?;
        }
        lua.globals().set("RENDER_STARBASE_STATE", t)?;
        Ok(())
    };
    set().map_err(|e| format!("starbase: {e}"))
}

/// The command protocol's `open_starbase [starbase] ID [tab N]` (headless.c serves it too): the
/// starbase's station fleet selected (its window opens), then a tab.
pub fn command(app: &mut App, args: &[&str]) -> Result<String, String> {
    let (kind, rest) = match args.first() {
        Some(k) if k.parse::<i64>().is_err() => (*k, &args[1..]),
        _ => ("starbase", args),
    };
    let id: i64 = rest.first().and_then(|v| v.parse().ok()).ok_or("open_starbase [starbase|waystation|megastructure|network] ID [tab N]")?;
    let tab: Option<u32> = rest.iter().position(|v| *v == "tab").and_then(|i| rest.get(i + 1)).and_then(|v| v.parse().ok());
    let galaxy = app.map.as_ref().ok_or("no map loaded")?.galaxy.clone();
    if kind == "megastructure" {
        // its window (CInGameIdler::ShowMegaStructureView after selecting it): the selection's
        // window closes
        prepare(&app.runtime, &galaxy, &app.starbase, false)?;
        let e: Vec<i64> = app.runtime.lua.load(format!("return require('render.windows.megastructure').owner({id})")).eval().map_err(|e| format!("megastructure: {e}"))?;
        if e.is_empty() {
            return Err(format!("open_starbase: no megastructure {id}"));
        }
        app.select(None);
        app.starbase.megastructure = Some(id);
        app.relayout();
        return Ok(format!("open_starbase megastructure {id}{} shown", if tab.is_some() { " tab" } else { "" }));
    }
    if kind != "starbase" {
        return Err(format!("open_starbase {kind}: not done yet"));
    }
    prepare(&app.runtime, &galaxy, &app.starbase, true)?;
    let fleet: Vec<i64> = app
        .runtime
        .lua
        .load(format!("return require('render.windows.starbase').fleet_of({id})"))
        .eval()
        .map_err(|e| format!("starbase: {e}"))?;
    let fleet = *fleet.first().ok_or(format!("open_starbase: no starbase {id}"))?;
    app.select(Some(Pickable::Fleet(fleet as u32)));
    app.starbase.megastructure = None;
    if let Some(t) = tab {
        app.starbase.tab = t;
    }
    app.relayout();
    let summary: String = app.runtime.lua.load(format!("return require('render.windows.starbase').summary({fleet})")).eval().unwrap_or_default();
    Ok(format!("open_starbase {kind} {id}{} shown ({summary})", if tab.is_some() { " tab" } else { "" }))
}

/// A click in the window (`starbase:...`): a tab, the previous or next starbase, the camera to it,
/// its planet's window.
pub fn act(app: &mut App, action: &str) -> Result<(), String> {
    let rest = action.strip_prefix("starbase:").unwrap_or(action);
    // the megastructure window's: closed; the camera to its system (CMegaStructureView::OnFocus [I]:
    // the system entered)
    if rest == "mega_close" {
        app.starbase.megastructure = None;
        app.relayout();
        return Ok(());
    }
    if rest == "mega_focus" {
        if let Some(id) = app.starbase.megastructure {
            let sys: Vec<i64> = app.runtime.lua.load(format!("local e = require('render.windows.megastructure').entry({id}) return e and {{ e.system }} or {{}}")).eval().map_err(|e| format!("megastructure: {e}"))?;
            let i = sys.first().and_then(|&s| app.map.as_ref().and_then(|m| m.galaxy.systems.iter().position(|x| x.id as i64 == s)));
            if let Some(i) = i {
                app.focus(Pickable::System(i))?;
            }
        }
        return Ok(());
    }
    let Some(Pickable::Fleet(fleet)) = app.selected else { return Ok(()) };
    let query = |app: &App, f: &str| -> Result<Vec<i64>, String> {
        app.runtime.lua.load(format!("return require('render.windows.starbase').{f}")).eval::<Vec<i64>>().map_err(|e| format!("starbase: {e}"))
    };
    if let Some(t) = rest.strip_prefix("tab:") {
        app.starbase.tab = t.parse().map_err(|_| format!("bad action {action}"))?;
        app.relayout();
    } else if rest == "prev" || rest == "next" {
        // CStarbaseView::OnPrevStarbaseClick / OnNextStarbaseClick: the owner's starbases in turn
        let dir = if rest == "next" { 1 } else { -1 };
        if let Some(&f) = query(app, &format!("neighbour({fleet}, {dir})"))?.first() {
            app.select(Some(Pickable::Fleet(f as u32)));
        }
    } else if rest == "goto" {
        // CAbstractStarbaseView::Goto: the camera to the starbase (its system entered, it followed)
        if let Some(&sys) = query(app, &format!("place({fleet})"))?.first() {
            let i = app.map.as_ref().and_then(|m| m.galaxy.systems.iter().position(|s| s.id as i64 == sys));
            if let Some(i) = i {
                app.focus(Pickable::System(i))?;
                app.focus(Pickable::Fleet(fleet))?;
            }
        }
    } else if rest == "planet" {
        // CStarbaseView::OnOpenPlanetClick: the planet's window
        if let Some(&p) = query(app, &format!("place({fleet})"))?.get(1) {
            if p >= 0 {
                app.select(Some(Pickable::Body(p as u32)));
            }
        }
    } else {
        app.log.push(format!("  {action}: not done yet"));
    }
    Ok(())
}

/// The megastructure window's flag (its header's `flag`, a flagSpriteType): its owner's
/// (CGameGraphics::ApplyCountryToButton); without an owner the sprite as it is.
pub fn flags(runtime: &Runtime, state: &State, map: &mut Map, items: &mut [GuiItem]) {
    let Some(id) = state.megastructure else { return };
    let owner: Vec<i64> = runtime.lua.load(format!("return require('render.windows.megastructure').owner({id})")).eval().unwrap_or_default();
    // an owner the player has no communications with shows the unknown flag (the Lua's emblem)
    let known = |o: i64| o == map.galaxy.player as i64 || map.galaxy.communications.as_ref().is_none_or(|c| c.iter().any(|&k| k as i64 == o));
    let country = owner.first().filter(|&&o| known(o)).and_then(|&o| map.galaxy.countries.iter().position(|c| c.id as i64 == o));
    for it in items.iter_mut() {
        if let GuiItem::Sprite { path, .. } = it {
            if path.starts_with("/megastructure_view/header/flag") {
                map.flags(std::slice::from_mut(it), country);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use stellar_sim::mlua::Table;

    /// The player's starport of the 2210.01.01 autosave, as the game's window shows it (when the
    /// save and the game's files are on this machine: STELLAR_SAVE, STELLARIS_DIR or 10.5.0.24's).
    #[test]
    fn starbase_values_of_2210() {
        let save = std::env::var("STELLAR_SAVE").unwrap_or_else(|_| "/opt/stellaris-saves/autosave_2210.01.01.sav".into());
        let game = std::env::var("STELLARIS_DIR").unwrap_or_else(|_| "/opt/stellaris".into());
        if !std::path::Path::new(&save).exists() || !std::path::Path::new(&game).join("common").exists() {
            eprintln!("skipped: no save or game files");
            return;
        }
        let rt = crate::galaxy::runtime(&save).expect("the save's world");
        let chunk = super::extract(&rt, &game);
        assert!(!chunk.is_empty(), "no starbase data");
        let t: Table = rt.lua.load(chunk.as_str()).eval().expect("the chunk");
        let e: Table = t.get::<Table>("starbases").unwrap().get(0).expect("fleet 0's starbase");
        // the game's frame: Starport, 2 of 6 module slots used and unlocked, 1 of 4 building
        // slots, hyperlane detection 2, sensor range 2, defense platforms 0/6, Starhold next
        assert_eq!(e.get::<String>("level").unwrap(), "starbase_level_starport");
        assert_eq!(e.get::<String>("next_size").unwrap(), "starbase_starhold");
        assert_eq!(e.get::<i64>("owner").unwrap(), 0);
        assert_eq!((e.get::<i64>("module_slots").unwrap(), e.get::<i64>("module_capacity").unwrap()), (6, 2));
        assert_eq!((e.get::<i64>("building_slots").unwrap(), e.get::<i64>("building_capacity").unwrap()), (4, 1));
        assert_eq!(e.get::<Table>("modules").unwrap().len().unwrap(), 2);
        assert_eq!((e.get::<i64>("hyperlane").unwrap(), e.get::<i64>("sensor").unwrap()), (2, 2));
        assert_eq!((e.get::<i64>("platforms").unwrap(), e.get::<i64>("platform_capacity").unwrap()), (0, 6));
        assert!(e.get::<bool>("shipyard").unwrap());
        assert!(!e.get::<bool>("upgrade_ok").unwrap(), "tech_starbase_3 is not researched");
    }
}
