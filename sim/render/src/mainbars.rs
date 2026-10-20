//! The main screen's own buttons (docs/windows/outliner.md section 8): the top bar's resource
//! groups and counters, the left bar (its lock, hover to expand), the bottom bar's map modes, map
//! filters and toolbar, the system and galaxy banners, the alerts (left click: what they point to,
//! right click: dismissed), the in-game menu (mainmenu_view.gui, Escape) and its confirmation
//! dialogs (standard_dialog.gui). The outliner's own buttons are outliner.rs's.
//!
//! Actions: `bar:...` (the bars), `alert:KEY` (an alert's banner), `menu:...` (the menu and its
//! dialogs). What the game does is read from the Linux 4.5.2 build (addresses in the doc).

use std::collections::{BTreeSet, HashMap};

use crate::app::App;
use crate::controls::Action;
use crate::scene::Pickable;

/// The bars' state (the player's clicks).
#[derive(Clone, Debug, Default)]
pub struct Bars {
    /// the map mode (CInGameIdler::SetCurrentMapMode: an index into common/map_modes; 0 default)
    pub map_mode: usize,
    /// the map filters (EMapFilter): sectors, hyperlanes, players on or off; details 0 off, 1
    /// details, 2 hide resources
    pub filters: [u8; 4],
    /// the left bar locked (CMainGui::ToggleLeftBarLock: hovering does not open it)
    pub lock: bool,
    /// the left bar open (the cursor over it, not locked)
    pub expanded: bool,
    /// the in-game menu open (CInGameIdler::ToggleMainMenu)
    pub menu: bool,
    /// the confirmation dialog open: "resign" or "quit"
    pub dialog: Option<String>,
    /// the alerts dismissed (a right click: CAlertManager::RightClick), until their condition ends
    pub dismissed: BTreeSet<String>,
    /// the alerts that walk a list (the next planet, fleet ...): the index reached
    pub cycle: HashMap<String, usize>,
    /// the load window opened from the menu (Escape returns to the map)
    pub load_from_game: bool,
    /// the save window open (the menu's Save: CInGameIdler::ShowSaveGameScreen)
    pub save: Option<SaveWindow>,
}

/// The save window (savegame_view.gui `SaveGameScreen`, CSaveGameView): the game's name, the file
/// name box (the date by default, as the user's own manual save `2200.01.11.sav` [V]), Save, and
/// the saves already in the game's folder (CGameState::GetSaveFolderName: save::save_folder_name).
#[derive(Clone, Debug, Default)]
pub struct SaveWindow {
    pub game: String,
    pub name: String,
    pub folder: std::path::PathBuf,
    /// the folder's saves, newest first: the file's name without `.sav`, the date, fleets, planets
    /// (each save's meta)
    pub saves: Vec<[String; 4]>,
}

/// The saves of a folder, newest first (as SaveWindow::saves).
fn folder_saves(folder: &std::path::Path) -> Vec<[String; 4]> {
    let mut out: Vec<(std::time::SystemTime, [String; 4])> = Vec::new();
    for e in std::fs::read_dir(folder).into_iter().flatten().flatten() {
        let p = e.path();
        if !p.extension().is_some_and(|x| x.eq_ignore_ascii_case("sav")) {
            continue;
        }
        let meta = stellar_sim::save::read_meta(&p.to_string_lossy()).unwrap_or_default();
        let value = |key: &str| {
            meta.lines().find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('='))).unwrap_or("").trim_matches('"').to_string()
        };
        let stem = p.file_stem().unwrap_or_default().to_string_lossy().into_owned();
        let t = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
        out.push((t, [stem, value("date"), value("meta_fleets"), value("meta_planets")]));
    }
    out.sort_by(|a, b| b.0.cmp(&a.0));
    out.into_iter().map(|(_, s)| s).collect()
}

/// The menu's Save: the save window over the menu, its name the date (the simulation's world).
fn open_save(app: &mut App) -> Result<(), String> {
    let Some(clock) = app.map.as_ref().and_then(|m| m.clock.as_ref()) else {
        note(app, "the save window: no simulation runs (a map without one cannot be saved)");
        return Ok(());
    };
    let (game, date) = clock.save_name()?;
    let root = stellar_sim::save::save_games_dir().ok_or("no folder for save games (HOME, USERPROFILE or STELLAR_SAVE_GAMES)")?;
    let folder = root.join(stellar_sim::save::save_folder_name(&game));
    let saves = folder_saves(&folder);
    app.bars.save = Some(SaveWindow { game, name: date, folder, saves });
    Ok(())
}

/// The save window's Save (its button, RETURN): the world written between days to the game's
/// folder (CSaveGameView::StartSave -> CInGameIdler::SaveGame); the window closes when it is done.
fn do_save(app: &mut App) -> Result<(), String> {
    let Some(w) = app.bars.save.as_ref() else { return Ok(()) };
    let path = w.folder.join(stellar_sim::save::save_file_name(&w.name));
    let path = path.to_string_lossy().into_owned();
    let clock = app.map.as_ref().and_then(|m| m.clock.as_ref()).ok_or("no simulation")?;
    match clock.save(&path) {
        Ok(date) => {
            app.log.push(format!("saved {date} to {path}"));
            app.bars.save = None;
        }
        Err(e) => app.log.push(format!("the save to {path} failed: {e}")),
    }
    Ok(())
}

/// The save window takes the keyboard while open (its file name box): a key typed (app.rs
/// creator_key's `creator:...`) as the window's action, or None.
pub fn save_typed(bars: &Bars, creator_action: &str) -> Option<String> {
    bars.save.as_ref()?;
    if let Some(c) = creator_action.strip_prefix("creator:text:") {
        return Some(format!("menu:save_text:{c}"));
    }
    creator_action.strip_prefix("creator:key:").map(|k| format!("menu:save_key:{k}"))
}

fn save_window(app: &mut App, rest: &str) -> Result<(), String> {
    match rest {
        "save_hide" => app.bars.save = None,
        "save_do" | "save_key:return" => do_save(app)?,
        "save_key:backspace" => {
            if let Some(w) = app.bars.save.as_mut() {
                w.name.pop();
            }
        }
        r if r.starts_with("save_text:") => {
            if let Some(w) = app.bars.save.as_mut() {
                // (the box's own limit is its width; a file name of 100 characters at most [I])
                if w.name.chars().count() < 100 {
                    w.name.push_str(&r["save_text:".len()..]);
                }
            }
        }
        r if r.starts_with("save_pick:") => {
            let i: usize = r["save_pick:".len()..].parse().unwrap_or(usize::MAX);
            if let Some(w) = app.bars.save.as_mut() {
                if let Some(s) = w.saves.get(i) {
                    w.name = s[0].clone();
                }
            }
        }
        _ => {}
    }
    Ok(())
}

/// The map filters' order in `Bars::filters` and their .gui names (main_bottom.gui toolbar).
pub const FILTERS: [&str; 4] = ["sectors", "hyperlanes", "details", "players"];

/// The left bar's views in their default order (CTopbarMenuOrderSettings::RevertToDefault: the
/// enum 0..9, 15, 16, 17) and their keys F1..F10 (CMainGuiLeftBarButton::Update).
pub const LEFT_BAR: [&str; 13] = [
    "situation", "council", "traditions", "technology", "leaders", "species", "empire", "expansion_planner", "fleet_manager", "contacts",
    "discoveries", "claims", "market",
];

/// Whether an action is the bars'.
pub fn handles(action: &str) -> bool {
    action.starts_with("bar:") || action.starts_with("alert:") || action.starts_with("menu:")
}

/// A view shown, not toggled (CInGameIdler::SetTopBarViewShown(e, true): the market stays open;
/// the others shown when they are not).
fn show_view(app: &mut App, name: &str) {
    if !app.view_shown(name) {
        app.toggle_view(name);
    }
}

/// A view toggled (ToggleTopBarView / ShowTopBarViewTab: a second click closes it).
fn toggle_view(app: &mut App, name: &str) {
    app.toggle_view(name);
}

fn note(app: &mut App, what: &str) {
    app.log.push(format!("{what}: not done here"));
}

/// A click's action.
pub fn act(app: &mut App, action: &str) -> Result<(), String> {
    if let Some(rest) = action.strip_prefix("bar:") {
        bar(app, rest)?;
    } else if let Some(key) = action.strip_prefix("alert:") {
        alert(app, key)?;
    } else if let Some(rest) = action.strip_prefix("menu:") {
        menu(app, rest)?;
    }
    app.relayout();
    Ok(())
}

fn bar(app: &mut App, rest: &str) -> Result<(), String> {
    let (what, arg) = rest.split_once(':').unwrap_or((rest, ""));
    match what {
        // the top bar's resource groups (onclick in interface/resource_groups: market, claims,
        // traditions; research: technology; the strategic ones: market; ShowTopBarViewTab)
        "res" => match arg {
            "tb_influence_group" => toggle_view(app, "claims"),
            "tb_unity_group" => toggle_view(app, "traditions"),
            "tb_research_group" => toggle_view(app, "technology"),
            "tb_biomass_group" => {}
            "tb_operational_reserves_group" => toggle_view(app, "situation"),
            g => {
                // the market (tab 21: shown, not toggled), on its Market tab with the resource
                show_view(app, "market");
                let r = match g {
                    "tb_energy_group" => Some("energy"),
                    "tb_mineral_group" => Some("minerals"),
                    "tb_food_group" => Some("food"),
                    "tb_consumer_goods_group" => Some("consumer_goods"),
                    "tb_alloys_group" => Some("alloys"),
                    "tb_trade_group" => Some("trade"),
                    _ => None,
                };
                let mut pairs = vec![("tab", "market")];
                if let Some(r) = r {
                    pairs.push(("resource", r));
                }
                app.set_view_state(&pairs);
            }
        },
        // the counters: naval capacity toggles the fleet manager; the envoys' window
        "navy" => toggle_view(app, "fleet_manager"),
        "envoys" => note(app, "the envoys' window (CInGameIdler::ShowEnvoyUnassignView)"),
        // the left bar's lock (frame 2 locked)
        "lock" => {
            app.bars.lock = !app.bars.lock;
            if app.bars.lock {
                app.bars.expanded = false;
            }
        }
        // the map modes (not a toggle) and filters (details cycles off, details, hide resources)
        "mapmode" => {
            app.bars.map_mode = arg.parse().unwrap_or(0);
            app.log.push(format!("map mode {}: the map's colours not done here", app.bars.map_mode));
        }
        "filter" => {
            if let Some(i) = FILTERS.iter().position(|f| *f == arg) {
                let f = &mut app.bars.filters[i];
                *f = if arg == "details" { (*f + 1) % 3 } else { 1 - (*f).min(1) };
                app.log.push(format!("map filter {arg} {}: its effect on the map not done here", app.bars.filters[i]));
            }
        }
        // the toolbar
        "menu" => toggle_menu(app)?,
        "home" => {
            app.perform(Action::HomeSystem)?;
        }
        "find" => note(app, "the search box (CInGameIdler::ToggleGotoBox)"),
        "chat" => note(app, "the multiplayer chat (ToggleInGameMPLobby)"),
        "databank" => note(app, "the databank (AccessDatabankWindow)"),
        // the banners: leave the system for the galaxy, or enter one (the camera's SwitchMode,
        // as E); the system's rename dialog
        "galaxy" | "system" => {
            app.perform(Action::ToggleSystem)?;
        }
        "rename" => note(app, "the system's rename dialog (CSystemRenameDialog)"),
        // a sector's icon in the outliner: the Planets view (OpenEmpireView)
        "sector" => show_view(app, "empire"),
        _ => app.log.push(format!("bar:{rest}: unknown")),
    }
    Ok(())
}

/// The in-game menu opened or closed (ToggleMainMenu @0x1c8a1d0): opening it closes the top bar
/// views and pauses a running game (single player).
pub fn toggle_menu(app: &mut App) -> Result<(), String> {
    let open = !app.bars.menu;
    if open {
        app.close_view();
        if !app.map.as_ref().is_some_and(|m| m.paused) {
            app.action("pause")?;
        }
    }
    app.bars.menu = open;
    app.bars.dialog = None;
    Ok(())
}

fn menu(app: &mut App, rest: &str) -> Result<(), String> {
    match rest {
        "resume" => app.bars.menu = false,
        "load" => {
            // the load window over the game (ShowLoadGameScreen); Escape comes back
            app.bars.load_from_game = true;
            app.action("open_load")?;
        }
        "save" => open_save(app)?,
        r if r.starts_with("save_") => save_window(app, r)?,
        "settings" => {
            // the menu closes, the settings open (ShowSettings)
            app.bars.menu = false;
            note(app, "the settings window (CSettingsView)");
        }
        "privacy" => {
            app.bars.menu = false;
            note(app, "the privacy policy (a browser)");
        }
        // the confirmation dialogs (CResignDialog, CQuitDialog: standard_dialog_quit_to_menu,
        // standard_dialog_quit)
        "resign" | "quit" => app.bars.dialog = Some(rest.to_string()),
        "dialog_no" => app.bars.dialog = None,
        "dialog_yes" => match app.bars.dialog.take().as_deref() {
            // CInGameIdler::DoResign: the main menu; Quit: the game ends
            Some("resign") => {
                app.bars.menu = false;
                app.resign();
            }
            Some("quit") => app.exit = true,
            _ => {}
        },
        // the menu's dimmed background takes the clicks
        "none" => {}
        _ => app.log.push(format!("menu:{rest}: unknown")),
    }
    Ok(())
}

/// The alerts that point to the next of a list: its targets in turn.
fn next_target(app: &mut App, key: &str) -> Option<i64> {
    let targets = alert_targets(app, key);
    if targets.is_empty() {
        return None;
    }
    let i = app.bars.cycle.entry(key.to_string()).or_insert(0);
    let t = targets[*i % targets.len()];
    *i += 1;
    Some(t)
}

/// An alert's targets (render.windows.alerts: `targets`), from the outliner's view.
fn alert_targets(app: &App, key: &str) -> Vec<i64> {
    use crate::outliner::LuaData;
    let Some(map) = app.map.as_ref() else { return Vec::new() };
    let Some(LuaData::Table(list)) = map.galaxy.outliner_view.get("alerts") else { return Vec::new() };
    for (_, a) in list {
        if matches!(a.get("key"), Some(LuaData::Str(k)) if k == key) {
            if let Some(LuaData::Table(t)) = a.get("targets") {
                let mut v: Vec<(f64, i64)> = t
                    .iter()
                    .filter_map(|(k, v)| match (k, v) {
                        (LuaData::Num(i), LuaData::Num(n)) => Some((*i, *n as i64)),
                        _ => None,
                    })
                    .collect();
                v.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
                return v.into_iter().map(|(_, n)| n).collect();
            }
        }
    }
    Vec::new()
}

/// An alert's left click (CAlertManager::Click @0x1dee550 and its On*Click handlers).
fn alert(app: &mut App, key: &str) -> Result<(), String> {
    let key = key.trim_start_matches("alert_");
    match key {
        // the technology view on the area (stays open, switches area)
        "physics_research" | "society_research" | "engineering_research" => {
            show_view(app, "technology");
            let area = key.trim_end_matches("_research");
            app.set_view_state(&[("select", area)]);
        }
        "unlock_tradition" | "unlock_ascension_perk" => toggle_view(app, "traditions"),
        "can_upgrade_government" | "inactive_civics" => toggle_view(app, "government"),
        "negative_income" | "resource_shortage" | "cannot_afford_monthly_trade" => show_view(app, "market"),
        "in_breach" => toggle_view(app, "edicts"),
        "activate_relic" | "astral_action_available" => toggle_view(app, "discoveries"),
        // the leaders and the council: shown directly
        "unspent_leader_trait_points" | "unassigned_leader" => show_view(app, "leaders"),
        "available_council_agenda" | "available_council_position" | "council_agenda_ready_for_activation" | "open_council_position" => {
            show_view(app, "council")
        }
        // the first contact's window
        "first_contact_stage_done" => {
            if let Some(id) = next_target(app, "alert_first_contact_stage_done") {
                app.action(&format!("fc:open:{id}"))?;
            }
        }
        // the next problem planet: the camera on it, selected
        "low_stability" | "declining_pops" | "necrophage_low_pops" => {
            if let Some(id) = next_target(app, &format!("alert_{key}")) {
                let p = Pickable::Body(id as u32);
                app.focus(p)?;
                app.select(Some(p));
            }
        }
        "timed_project" | "imminent_situation" | "situation_blocked" => show_view(app, "situation"),
        "can_modify_species" => show_view(app, "species"),
        _ => note(app, &format!("alert {key}'s window")),
    }
    Ok(())
}

/// A right click on a GUI element (CAlertManager::RightClick: dismissed; an outliner row's
/// FocusCamera): whether it was taken.
pub fn right_click(app: &mut App, x: f32, y: f32) -> Result<bool, String> {
    let Some((path, action)) = app.button_at(x, y)? else { return Ok(false) };
    let Some(a) = action else { return Ok(true) };
    if let Some(key) = a.strip_prefix("alert:") {
        app.bars.dismissed.insert(key.to_string());
        app.log.push(format!("alert {key} dismissed"));
        app.relayout();
        return Ok(true);
    }
    if path.starts_with("/outliner") {
        if let Some(p) = pickable(&a) {
            app.focus(p)?;
        }
        return Ok(true);
    }
    // the other GUI elements take no right click
    Ok(true)
}

/// The thing a `select:KIND:ID` action names.
pub fn pickable(action: &str) -> Option<Pickable> {
    let mut it = action.strip_prefix("select:")?.split(':');
    let kind = it.next()?;
    let id: u32 = it.next()?.parse().ok()?;
    Some(match kind {
        "planet" => Pickable::Body(id),
        "system" => Pickable::System(id as usize),
        _ => Pickable::Fleet(id),
    })
}

/// Escape (the .gui shortcuts ESCAPE: the dialog's Decline, the menu's Resume, else the toolbar's
/// menu button): whether it was taken. `first`: before the other windows (the menu and its
/// dialog are over them); else the fall-through, nothing else open.
pub fn escape(app: &mut App, first: bool) -> Result<bool, String> {
    if app.bars.dialog.is_some() {
        app.bars.dialog = None;
    } else if app.bars.save.is_some() {
        // the save window's close button (shortcut ESCAPE)
        app.bars.save = None;
    } else if app.bars.menu {
        app.bars.menu = false;
    } else if first && app.outliner.popup != 0 {
        // the outliner's options or rearrange window (its close button: ESCAPE)
        app.outliner.popup = 0;
    } else if first {
        return Ok(false);
    } else {
        toggle_menu(app)?;
    }
    app.relayout();
    Ok(true)
}

/// The cursor moved: the left bar opens under it (unless locked) and closes when it leaves.
/// Whether the windows must be laid out again.
pub fn hover(app: &mut App, x: f32, y: f32) -> bool {
    let (_, h) = app.size;
    // the bar's strip: collapsed, its 35 visible pixels; open, its 245 (show_position -5 + the
    // background's 250) [I: the hit area the window's]
    let width = if app.bars.expanded { 245.0 } else { 35.0 };
    let over = x < width && y > 35.0 && y < (35.0_f32 + 610.0).min(h as f32);
    let open = over && !app.bars.lock;
    if open != app.bars.expanded {
        app.bars.expanded = open;
        return true;
    }
    false
}

/// The .gui shortcuts of the bars (key released): the left bar's F1..F10, the toolbar's (F
/// search, L chat, Alt+B databank), the map modes' (Ctrl+Z, M, X, N, C, V, B), O the outliner.
/// The action to do, if any.
pub fn shortcut(key: &str, ctrl: bool, alt: bool, shift: bool) -> Option<String> {
    if shift {
        return None;
    }
    if ctrl && !alt {
        let modes = ["z", "m", "x", "n", "c", "v", "b"];
        return modes.iter().position(|m| *m == key).map(|i| format!("bar:mapmode:{i}"));
    }
    if alt {
        return (key == "b" && !ctrl).then(|| "bar:databank".to_string());
    }
    if let Some(n) = key.strip_prefix('f').and_then(|n| n.parse::<usize>().ok()) {
        return (1..=10).contains(&n).then(|| format!("view:{}", LEFT_BAR[n - 1]));
    }
    match key {
        "f" => Some("bar:find".into()),
        "l" => Some("bar:chat".into()),
        "o" => Some("outliner:tabbed".into()),
        _ => None,
    }
}

/// The modal window open (the menu's dialog, else the menu): the prefix of the buttons that take
/// the input.
pub fn modal(bars: &Bars) -> Option<&'static str> {
    match bars.dialog.as_deref() {
        Some("resign") => Some("/standard_dialog_quit_to_menu"),
        Some(_) => Some("/standard_dialog_quit"),
        None if bars.save.is_some() => Some("/SaveGameScreen"),
        None if bars.menu => Some("/mainmenu_window"),
        None => None,
    }
}

/// The in-game menu (mainmenu_view.gui `mainmenu_window`: a dimmed screen taking the clicks, the
/// 360 x 600 panel at the centre) and its confirmation dialog (standard_dialog.gui), laid out over
/// every other window.
pub fn menu_items(runtime: &stellar_sim::Runtime, w: u32, h: u32, bars: &Bars, version: &str) -> Result<Vec<crate::gui::GuiItem>, String> {
    use crate::gui::WindowSpec;
    if !bars.menu && bars.dialog.is_none() && bars.save.is_none() {
        return Ok(Vec::new());
    }
    let mut specs = Vec::new();
    if bars.menu {
        let mut m = WindowSpec::new("interface/mainmenu_view.gui", "mainmenu_window");
        let p = "/mainmenu_window/window";
        m.actions.push(("/mainmenu_window".into(), "menu:none".into()));
        for b in ["save", "load", "settings", "resign", "quit", "resume", "privacy"] {
            m.actions.push((format!("{p}/{b}"), format!("menu:{b}")));
        }
        // (no Ironman: the save and load buttons enabled, their Ironman icons hidden)
        m.hide = vec!["ironman_icon_save".into(), "ironman_icon_load".into(), "version_button".into()];
        m.text.push((format!("{p}/version"), version.to_string()));
        specs.push(m);
    }
    if let Some(d) = bars.dialog.as_deref() {
        // CResignDialog: standard_dialog_quit_to_menu, RESIGN_TITLE, RESIGN_DESC; CQuitDialog:
        // standard_dialog_quit (its title QUIT_TITLE [I])
        let (window, title, desc) = if d == "resign" {
            ("standard_dialog_quit_to_menu", "RESIGN_TITLE", "RESIGN_DESC")
        } else {
            ("standard_dialog_quit", "QUIT_TITLE", "")
        };
        let mut s = WindowSpec::new("interface/standard_dialog.gui", window);
        let p = format!("/{window}");
        s.actions.push((p.clone(), "menu:none".into()));
        s.actions.push((format!("{p}/AgreeButton"), "menu:dialog_yes".into()));
        s.actions.push((format!("{p}/DeclineButton"), "menu:dialog_no".into()));
        s.text.push((format!("{p}/title"), title.into()));
        s.text.push((format!("{p}/description"), desc.into()));
        specs.push(s);
    }
    let mut items = crate::gui::layout_specs(runtime, w, h, &specs)?.items;
    if let Some(s) = &bars.save {
        items.extend(save_items(runtime, w, h, s)?);
    }
    Ok(items)
}

/// The save window laid out (over the menu): SaveGameScreen with the game's name and the file name
/// box, then a SaveSaveGameEntry for each save in the folder down its list (spacing -4). No cloud:
/// its checkbox, label and icon hidden, each entry's cloud_file at its first frame (a local file)
/// and its delete button hidden [I].
fn save_items(runtime: &stellar_sim::Runtime, w: u32, h: u32, s: &SaveWindow) -> Result<Vec<crate::gui::GuiItem>, String> {
    use crate::gui::WindowSpec;
    const FILE: &str = "interface/savegame_view.gui";
    let p = "/SaveGameScreen";
    let mut m = WindowSpec::new(FILE, "SaveGameScreen");
    m.actions.push((p.into(), "menu:none".into()));
    m.actions.push((format!("{p}/hide"), "menu:save_hide".into()));
    m.actions.push((format!("{p}/save"), "menu:save_do".into()));
    m.hide = vec!["cloud_save".into(), "cloud_save_label".into(), "cloud_icon".into()];
    m.text.push((format!("{p}/game_name"), s.game.clone()));
    // (the box's cursor: a bar after the text [I])
    m.text.push((format!("{p}/filename"), format!("{}|", s.name)));
    let main = crate::gui::layout_specs(runtime, w, h, &[m])?;
    let mut items = main.items;
    let Some(list) = main.rects.get(&format!("{p}/list")).copied() else { return Ok(items) };
    let (ew, eh) = (560.0, 58.0);
    let mut entries = Vec::new();
    for (i, save) in s.saves.iter().enumerate() {
        let y = list[1] + i as f32 * (eh - 4.0);
        if y + eh > list[1] + list[3] {
            break;
        }
        let prefix = format!("{p}/list/{i}");
        let e = format!("{prefix}/SaveSaveGameEntry");
        let mut spec = WindowSpec::new(FILE, "SaveSaveGameEntry");
        spec.prefix = Some(prefix.clone());
        // (the entry is `orientation = center`: its parent's centre is the slot's corner plus half
        // the entry, as render.loadgame's)
        spec.parent = Some([list[0] - ew / 2.0, y - eh / 2.0, ew, eh]);
        spec.hide = vec!["delete".into()];
        spec.frames.push((format!("{e}/cloud_file"), 1));
        spec.actions.push((format!("{e}/bg"), format!("menu:save_pick:{i}")));
        spec.text.push((format!("{e}/name"), save[0].clone()));
        spec.text.push((format!("{e}/date"), save[1].clone()));
        spec.text.push((format!("{e}/filename"), format!("{}.sav", save[0])));
        spec.text.push((format!("{e}/fleets"), save[2].clone()));
        spec.text.push((format!("{e}/planets"), save[3].clone()));
        entries.push(spec);
    }
    if !entries.is_empty() {
        items.extend(crate::gui::layout_specs(runtime, w, h, &entries)?.items);
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcuts() {
        assert_eq!(shortcut("f1", false, false, false).as_deref(), Some("view:situation"));
        assert_eq!(shortcut("f10", false, false, false).as_deref(), Some("view:contacts"));
        assert_eq!(shortcut("f11", false, false, false), None);
        assert_eq!(shortcut("z", true, false, false).as_deref(), Some("bar:mapmode:0"));
        assert_eq!(shortcut("b", false, true, false).as_deref(), Some("bar:databank"));
        assert_eq!(shortcut("o", false, false, false).as_deref(), Some("outliner:tabbed"));
        assert_eq!(shortcut("w", false, false, false), None);
    }

    #[test]
    fn pickables() {
        assert_eq!(pickable("select:planet:5"), Some(Pickable::Body(5)));
        assert_eq!(pickable("select:fleet:3"), Some(Pickable::Fleet(3)));
        assert_eq!(pickable("outliner:tab:1"), None);
    }
}
