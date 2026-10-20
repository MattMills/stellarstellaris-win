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
    /// the selected starbase shown in the waystation window whatever its type (`open_starbase
    /// waystation ID`, as headless.c's ShowWaystationView on any starbase)
    pub waystation: bool,
    /// the waystation network whose window is open (its save id)
    pub network: Option<i64>,
    /// the Command tab's side view: the slot clicked (`module:N`, `building:N`, 1-based)
    pub side: Option<String>,
    /// the side view's sublists closed (CBuildableShipListSubList::ToggleOpenStatus: "civilian", a
    /// size's key, `cat:CATEGORY`)
    pub closed: Vec<String>,
    /// the confirmation dialog open: the command it confirms (`VERB:ARG...`)
    pub dialog: Option<String>,
    /// the rename dialog's text as typed (None: the station's name, untouched)
    pub text: Option<String>,
    /// the window's lists scrolled down (the wheel over them): by list (the side view's `side`, a
    /// list's path), in pixels
    pub scroll: std::collections::HashMap<String, f32>,
}

/// The wheel over one of the window's lists (their areas and ranges from the last layout: the
/// Lua's scroll_areas): it scrolls, 20 pixels a notch (the game's frames: the side view's list);
/// whether it took the wheel.
pub fn wheel(app: &mut App, notches: f32) -> bool {
    let Some((x, y)) = app.cursor else { return false };
    if app.selected.is_none() {
        return false;
    }
    let code = "local m = package.loaded['render.windows.starbase'] local out = {} \
                for _, a in ipairs(m and m.scroll_areas or {}) do out[#out + 1] = string.format('%s %f %f %f %f %f', a.key, a.x, a.y, a.w, a.h, a.max) end \
                return out";
    let areas: Vec<String> = app.runtime.lua.load(code).eval().unwrap_or_default();
    for a in areas {
        let f: Vec<&str> = a.split(' ').collect();
        let [key, ax, ay, aw, ah, max] = f[..] else { continue };
        let n = |s: &str| s.parse::<f32>().unwrap_or(0.0);
        let (ax, ay, aw, ah, max) = (n(ax), n(ay), n(aw), n(ah), n(max));
        if x < ax || x > ax + aw || y < ay || y > ay + ah {
            continue;
        }
        let now = app.starbase.scroll.get(key).copied().unwrap_or(0.0);
        let s = (now - notches * 20.0).clamp(0.0, max.max(0.0));
        if s != now {
            app.starbase.scroll.insert(key.to_string(), s);
            app.relayout();
        }
        return true;
    }
    false
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
        t.set("waystation", state.waystation)?;
        t.set("network", state.network)?;
        t.set("side", state.side.clone())?;
        t.set("closed", state.closed.join(","))?;
        t.set("dialog", state.dialog.clone())?;
        t.set("text", state.text.clone())?;
        let scroll: Vec<String> = state.scroll.iter().map(|(k, v)| format!("{k}={v}")).collect();
        t.set("scroll", scroll.join(","))?;
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
        app.starbase.network = None;
        app.starbase.megastructure = Some(id);
        app.relayout();
        return Ok(format!("open_starbase megastructure {id}{} shown", if tab.is_some() { " tab" } else { "" }));
    }
    if kind == "network" {
        // its window (CInGameIdler::ShowWaystationNetworkView after selecting it)
        prepare(&app.runtime, &galaxy, &app.starbase, false)?;
        open_network(app, id)?;
        return Ok(format!("open_starbase network {id} shown"));
    }
    if kind != "starbase" && kind != "waystation" {
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
    app.starbase.network = None;
    app.starbase.waystation = kind == "waystation";
    if let Some(t) = tab {
        app.starbase.tab = t;
    }
    app.relayout();
    let summary: String = app.runtime.lua.load(format!("return require('render.windows.starbase').summary({fleet})")).eval().unwrap_or_default();
    Ok(format!("open_starbase {kind} {id}{} shown ({summary})", if tab.is_some() { " tab" } else { "" }))
}

/// A command of the starbase windows (`VERB:ARG:...`): render.windows.starbase_commands.run in the
/// simulation's runtime between days (its world, definitions, economy), then a snapshot published
/// and taken. What it did, for the log.
fn run_command(app: &mut App, cmd: &str) -> Result<String, String> {
    let args: Vec<String> = cmd.split(':').map(|a| format!("{a:?}")).collect();
    let code = format!("return tostring(require('render.windows.starbase_commands').run({}))", args.join(", "));
    let map = app.map.as_mut().ok_or("no map")?;
    map.ready()?;
    let clock = map.clock.as_ref().ok_or("no simulation")?;
    let r = clock.command("starbase command", &code).map_err(|e| format!("render.windows.starbase_commands: {e}"))?;
    clock.publish(true);
    map.sync();
    Ok(r)
}

/// A key typed while the rename dialog is open: its action (`starbase:text:C`, `starbase:key:NAME`),
/// from the empire creator's key names (app.rs creator_key); None when no dialog takes keys.
pub fn typed(state: &State, creator_action: &str) -> Option<String> {
    if !state.dialog.as_deref().is_some_and(|d| d.starts_with("rename:")) {
        return None;
    }
    if let Some(c) = creator_action.strip_prefix("creator:text:") {
        return Some(format!("starbase:text:{c}"));
    }
    creator_action.strip_prefix("creator:key:").map(|k| format!("starbase:key:{k}"))
}

/// The waystation network window on network `id` (the selection's window closes).
fn open_network(app: &mut App, id: i64) -> Result<(), String> {
    let e: Vec<i64> = app.runtime.lua.load(format!("return require('render.windows.network').owner({id})")).eval().map_err(|e| format!("network: {e}"))?;
    if e.is_empty() {
        return Err(format!("open_starbase: no waystation network {id}"));
    }
    app.select(None);
    app.starbase.megastructure = None;
    app.starbase.network = Some(id);
    app.relayout();
    Ok(())
}

/// A click in the window (`starbase:...`): a tab, the previous or next starbase, the camera to it,
/// its planet's window.
pub fn act(app: &mut App, action: &str) -> Result<(), String> {
    let rest = action.strip_prefix("starbase:").unwrap_or(action);
    // the megastructure window's: closed; the camera to its system (CMegaStructureView::OnFocus [I]:
    // the system entered)
    // the network window's: closed; another network (the waystation window's network box, a
    // connected network's entry); the owner's networks in turn (CWaystationNetworkView::OnPrevClick
    // / OnNextClick [I]: by id)
    if rest == "network_close" {
        app.starbase.network = None;
        app.relayout();
        return Ok(());
    }
    if let Some(id) = rest.strip_prefix("network_open:") {
        let id: i64 = id.parse().map_err(|_| format!("bad action {action}"))?;
        return open_network(app, id);
    }
    if rest == "network_prev" || rest == "network_next" {
        if let Some(id) = app.starbase.network {
            let dir = if rest == "network_next" { 1 } else { -1 };
            let code = format!(
                "local d = require('render.windows.starbase').data() local n = d and d.networks or {{}} local me = n[{id}] local ids = {{}} \
                 for k, v in pairs(n) do if me and v.owner == me.owner then ids[#ids + 1] = k end end table.sort(ids) \
                 for i, k in ipairs(ids) do if k == {id} then return {{ ids[(i - 1 + {dir}) % #ids + 1] }} end end return {{}}"
            );
            let next: Vec<i64> = app.runtime.lua.load(code).eval().map_err(|e| format!("network: {e}"))?;
            if let Some(&n) = next.first() {
                open_network(app, n)?;
            }
        }
        return Ok(());
    }
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
    // a command's confirmation dialog (standard_dialog): its Agree runs it (the starbase,
    // waystation and megastructure windows')
    if let Some(cmd) = rest.strip_prefix("dialog:") {
        app.starbase.dialog = Some(cmd.to_string());
        app.starbase.text = None;
        app.relayout();
        return Ok(());
    }
    if rest == "dialog_no" || rest == "none" {
        // (the dialog's background takes a click)
        if rest == "dialog_no" {
            app.starbase.dialog = None;
            app.starbase.text = None;
            app.relayout();
        }
        return Ok(());
    }
    // the rename dialog's typing: a character (`:` would split the command: left out), Backspace,
    // Return (OK), Escape (Cancel)
    if let Some(c) = rest.strip_prefix("text:") {
        if c != ":" {
            // (the box starts with the station's name: typing goes on from it)
            if app.starbase.text.is_none() {
                let name: Option<String> = app.runtime.lua.load("local d = RENDER_STARBASE_DIALOG_NAME return d").eval().ok().flatten();
                app.starbase.text = name;
            }
            app.starbase.text.get_or_insert_with(String::new).push_str(c);
            app.relayout();
        }
        return Ok(());
    }
    if let Some(k) = rest.strip_prefix("key:") {
        match k {
            "backspace" => {
                // (the box starts with the station's name: the first Backspace edits it)
                if app.starbase.text.is_none() {
                    let name: Option<String> = app.runtime.lua.load("local d = RENDER_STARBASE_DIALOG_NAME return d").eval().ok().flatten();
                    app.starbase.text = name;
                }
                if let Some(t) = app.starbase.text.as_mut() {
                    t.pop();
                }
                app.relayout();
            }
            "return" => return act(app, "starbase:dialog_yes"),
            "escape" => return act(app, "starbase:dialog_no"),
            _ => {}
        }
        return Ok(());
    }
    if rest == "dialog_yes" {
        let text = app.starbase.text.take();
        if let Some(mut cmd) = app.starbase.dialog.take() {
            if cmd.starts_with("rename:") {
                // OK with the name untouched: nothing to do
                let Some(t) = text.filter(|t| !t.trim().is_empty()) else {
                    app.relayout();
                    return Ok(());
                };
                cmd = format!("{cmd}:{}", t.trim());
            }
            let r = run_command(app, &cmd)?;
            app.log.push(format!("starbase: {r}"));
            if cmd.starts_with("dismantle_component") && r.starts_with("ok") {
                app.starbase.side = None;
            }
        }
        app.relayout();
        return Ok(());
    }
    // the megastructure window's commands (no selection)
    if let Some(cmd) = rest.strip_prefix("cmd:mega_") {
        let r = run_command(app, &format!("mega_{cmd}"))?;
        app.log.push(format!("starbase: {r}"));
        app.relayout();
        return Ok(());
    }
    let Some(Pickable::Fleet(fleet)) = app.selected else { return Ok(()) };
    let query = |app: &App, f: &str| -> Result<Vec<i64>, String> {
        app.runtime.lua.load(format!("return require('render.windows.starbase').{f}")).eval::<Vec<i64>>().map_err(|e| format!("starbase: {e}"))
    };
    if let Some(t) = rest.strip_prefix("tab:") {
        // ShowTab: the tab's own side view (the Command tab's after a slot is clicked)
        app.starbase.tab = t.parse().map_err(|_| format!("bad action {action}"))?;
        app.starbase.side = None;
        app.starbase.scroll.clear();
        app.relayout();
    } else if let Some(slot) = rest.strip_prefix("slot:") {
        // a grid slot (CStarbaseComponentGridEntry, the tab controller its observer): the side view
        // of that slot (its component, or the buildables), the same slot again closes it [I]
        let slot = format!("{fleet}:{slot}");
        app.starbase.side = if app.starbase.side.as_deref() == Some(slot.as_str()) { None } else { Some(slot) };
        app.starbase.scroll.remove("side");
        app.relayout();
    } else if let Some(key) = rest.strip_prefix("sub:") {
        // a sublist's header: open or closed
        let key = key.to_string();
        if let Some(i) = app.starbase.closed.iter().position(|k| *k == key) {
            app.starbase.closed.remove(i);
        } else {
            app.starbase.closed.push(key);
        }
        app.relayout();
    } else if let Some(cmd) = rest.strip_prefix("cmd:") {
        // a command (render.windows.starbase_commands) in the simulation between days, then a
        // snapshot published and taken: the window shows the world it made
        // (the side view stays open: the game's frame greys the slot's other choices)
        let r = run_command(app, cmd)?;
        app.log.push(format!("starbase: {r}"));
        app.relayout();
    } else if rest.starts_with("designer:") {
        // OpenShipDesigns / OpenDefenseDesigns: the ship designer (its design list) [I: the
        // designer opens on no design]
        app.set_designer(crate::designer::Designer { open: true, design: None });

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
    // the waystation window's owner box: its owner met and not the player's (the Lua's flag_owner)
    let way: Option<i64> = runtime.lua.load("return package.loaded['render.windows.waystation'] and package.loaded['render.windows.waystation'].flag_owner").eval().ok().flatten();
    if let Some(o) = way {
        let country = map.galaxy.countries.iter().position(|c| c.id as i64 == o);
        for it in items.iter_mut() {
            if let GuiItem::Sprite { path, .. } = it {
                if path.starts_with("/waystation_view/planet_view_module_spaceport_portrait/owner/flag") {
                    map.flags(std::slice::from_mut(it), country);
                }
            }
        }
    }
    // the network window's list: the stations' system owner and the connected networks' owner flags,
    // the network's owner [I]
    if let Some(id) = state.network {
        let owner: Vec<i64> = runtime.lua.load(format!("return require('render.windows.network').owner({id})")).eval().unwrap_or_default();
        let country = owner.first().and_then(|&o| map.galaxy.countries.iter().position(|c| c.id as i64 == o));
        for it in items.iter_mut() {
            if let GuiItem::Sprite { path, .. } = it {
                if path.starts_with("/waystation_network_view/list/") && (path.ends_with("/system_owner_flag") || path.ends_with("/owner_flag")) {
                    map.flags(std::slice::from_mut(it), country);
                }
            }
        }
    }
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
