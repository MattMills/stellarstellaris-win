//! A new game started in the renderer (docs/windows/newgame_start.md): the setup's settings, the
//! galaxy generated in Lua on the simulation's thread (sim/lua/engine/newgame, docs/newgame.md),
//! its world handed to the engine as a tree (no save written or parsed), the start script run, the
//! clock started on it paused at 2200.01.01; and the game's load screen while it runs, its bar as
//! the game moves it.
//!
//! The game **[V]** (4.5.2 Linux build, /root/re452 on hippo): `CFrontEndIdler::LaunchNewGame`
//! (0x25c57b0) creates the load screen, draws it at 0 with `START_NEW_GAME` ("Starting New Game"),
//! zeroes `s_nWorldGenProgress`, runs the generation as a task (`GenerateNewGalaxy`) and, until it
//! is done, every 16 ms (nanosleep 16,000,000 ns): when the bar shown (a float, from 0) is not the
//! progress, `shown = 0.9 shown + 0.1 T(progress)` and the screen is drawn at `trunc(shown)`.
//! `T` is the load screen's progress context (`CLoadScreenProgressContext::GetTransformed`: the top
//! state's `start + span * p / 100`, integers), whose states nest (`PushState(a, b)` on a state
//! {s, k}: {s + k a / 100, k (b - a) / 100}): LaunchNewGame pushes (0, 50) -> {0, 50},
//! GenerateNewGalaxy (0, 75) around `CGalaxyGenerator::Generate` -> {0, 37}, then (75, 100) around
//! `InitPostGalaxyCreation` -> {37, 12}. The progress is `SetWorldGenerationProgress` (0x25c95d0)'s:
//! 5, 10, 17, 20 + 50 i / n (fallen empires), 70 + 30 i / n (every system); see
//! engine/newgame/init.lua. Then the screen is drawn at 50, the in-game idler made, and its
//! `RestoreDeviceObjects` (0x1c97c30) pushes (50, 75), drawing `LOAD_MAP_GFX` ("Loading Map
//! Graphics") at its steps (at most once each 1/60 s) up to 100 (= 75 on the bar), and
//! `DestroyLoadScreen`.

use std::sync::atomic::{AtomicI32, AtomicU8, Ordering};
use std::sync::Arc;

use stellar_sim::mlua::{self, Table};
use stellar_sim::{Date, Runtime};

/// What the setup gives a new game: newgame.generate's settings (`values`: KEY -> VALUE as text;
/// numbers, `yes` / `no` read as such) and the player's empire design (`empire`: a prescripted
/// design's key, or a whole design `key = { ... }` in user_empire_designs.txt's form).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NewGameSettings {
    pub values: Vec<(String, String)>,
    pub empire: Option<String>,
}

/// The settings newgame.generate reads (engine/newgame/scenario.lua, init.lua).
pub const KEYS: &[&str] = &[
    "scenario", "shape", "empires", "fallen_empires", "marauders", "nomads", "advanced_empires",
    "num_hyperlanes", "num_gateways", "num_wormhole_pairs", "habitability", "primitive", "crises",
    "difficulty", "player_locations", "clustered", "seed", "global_seed", "name", "start_year",
];

impl NewGameSettings {
    /// `KEY=VALUE` words (the `newgame` command's): the keys of [`KEYS`], `empire=DESIGN`,
    /// `designs=FILE` (a user_empire_designs file: the designs the setup offers, settings
    /// `designs_text`), `global_at=STEP=N,...` (the global stream put at the game's positions when
    /// the generator's steps start: docs/newgame.md 8.1; `_` for a space in a step's name:
    /// `global_at=hyperlanes=5382,empire_systems=5384`).
    pub fn parse(words: &[&str]) -> Result<NewGameSettings, String> {
        let mut s = NewGameSettings::default();
        for w in words {
            let (k, v) = w.split_once('=').ok_or(format!("{w}: KEY=VALUE"))?;
            if k == "designs" {
                let text = std::fs::read_to_string(v).map_err(|e| format!("designs={v}: {e}"))?;
                s.set("designs_text", &text);
            } else if k == "global_at" {
                s.set("global_at", &v.replace('_', " "));
            } else if k == "empire" {
                s.empire = Some(v.to_string());
            } else if KEYS.contains(&k) {
                s.set(k, v);
            } else {
                return Err(format!("{k}: not a setting ({} or empire)", KEYS.join(", ")));
            }
        }
        Ok(s)
    }

    /// The setup screens' settings table (render.newgame_setup.settings): every text, number and
    /// boolean key passed on (the generator ignores those it does not read), `empire = { kind,
    /// key, design }`: prescripted -> its key, custom -> its design (a text, or the empire
    /// creator's table made text by render.creator_rules.to_text(design, key)), random -> none.
    pub fn from_lua(lua: &mlua::Lua, t: &Table) -> mlua::Result<NewGameSettings> {
        let mut s = NewGameSettings::default();
        let mut keys: Vec<(String, String)> = Vec::new();
        for pair in t.pairs::<mlua::Value, mlua::Value>() {
            let (k, v) = pair?;
            let mlua::Value::String(k) = k else { continue };
            let k = k.to_str()?.to_string();
            let text = match v {
                mlua::Value::String(v) => v.to_str()?.to_string(),
                mlua::Value::Integer(n) => n.to_string(),
                mlua::Value::Number(n) => n.to_string(),
                mlua::Value::Boolean(b) => (if b { "yes" } else { "no" }).to_string(),
                mlua::Value::Table(e) if k == "empire" => {
                    let kind: Option<String> = e.get("kind")?;
                    s.empire = match kind.as_deref() {
                        Some("custom") => match e.get::<mlua::Value>("design")? {
                            mlua::Value::String(d) => Some(d.to_str()?.to_string()),
                            mlua::Value::Table(d) => {
                                let key = e.get::<Option<String>>("key")?.unwrap_or_else(|| "player_design".into());
                                let to_text: mlua::Function = lua.load("return require('render.creator_rules').to_text").eval()?;
                                Some(to_text.call::<String>((d, key))?)
                            }
                            _ => e.get("key")?,
                        },
                        Some("random") => None,
                        _ => e.get("key")?,
                    };
                    continue;
                }
                _ => continue,
            };
            keys.push((k, text));
        }
        keys.sort();
        for (k, v) in keys {
            s.set(&k, &v);
        }
        Ok(s)
    }

    pub fn set(&mut self, key: &str, value: &str) {
        self.values.retain(|(k, _)| k != key);
        self.values.push((key.to_string(), value.to_string()));
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    /// The seed of the game's global generator (the runtime's: `RUST.rand`), 0 by default.
    pub fn global_seed(&self) -> u32 {
        self.get("global_seed").and_then(|v| v.parse().ok()).unwrap_or(0)
    }

    /// As words, for the log and the command's reply.
    pub fn describe(&self) -> String {
        let mut w: Vec<String> = self
            .values
            .iter()
            .map(|(k, v)| if k == "designs_text" { format!("designs=<{} bytes>", v.len()) } else { format!("{k}={v}") })
            .collect();
        if let Some(e) = &self.empire {
            w.push(if e.contains('{') { "empire=<design>".into() } else { format!("empire={e}") });
        }
        if w.is_empty() {
            "the scenario's defaults".into()
        } else {
            w.join(" ")
        }
    }

    /// newgame.generate's settings table.
    fn to_lua(&self, lua: &mlua::Lua) -> mlua::Result<Table> {
        let t = lua.create_table()?;
        for (k, v) in &self.values {
            match (v.as_str(), v.parse::<f64>()) {
                ("yes", _) => t.set(k.as_str(), true)?,
                ("no", _) => t.set(k.as_str(), false)?,
                (_, Ok(n)) if k != "name" && k != "designs_text" && k != "global_at" => t.set(k.as_str(), n)?,
                _ => t.set(k.as_str(), v.as_str())?,
            }
        }
        match &self.empire {
            Some(e) if e.contains('{') => t.set("player_design_text", e.as_str())?,
            Some(e) => t.set("player_design", e.as_str())?,
            None => {}
        }
        Ok(t)
    }
}

/// Where the start is, shared by the simulation's thread and the window: the game's world
/// generation progress (0..100) and the stage.
#[derive(Default)]
pub struct Progress {
    pub world_gen: AtomicI32,
    pub stage: AtomicU8,
}

/// The stages: the galaxy generated (CGalaxyGenerator::Generate), then the game made from it (the
/// engine's load and the start script: InitPostGalaxyCreation, OnNewGameStarted's script), then
/// ready.
pub const GENERATING: u8 = 0;
pub const POST: u8 = 1;
pub const READY: u8 = 2;

impl Progress {
    pub fn stage(&self) -> u8 {
        self.stage.load(Ordering::Relaxed)
    }
    pub fn world_gen(&self) -> i32 {
        self.world_gen.load(Ordering::Relaxed)
    }
}

/// The simulation's runtime of a new game: generated in it (the global stream it draws from is the
/// runtime's, seeded with `global_seed`), loaded from the generated tree, the start script run.
/// Returns the runtime and what was done.
pub fn sim_runtime(game_dir: &str, settings: &NewGameSettings, progress: &Arc<Progress>) -> Result<(Runtime, String), String> {
    let t0 = std::time::Instant::now();
    let start = Date::from_ymd(2200, 1, 1);
    let runtime = Runtime::new(start, settings.global_seed()).map_err(|e| format!("the Lua runtime: {e}"))?;
    let lua = &runtime.lua;
    let run = || -> mlua::Result<String> {
        let s = settings.to_lua(lua)?;
        s.set("tree_only", true)?;
        let p = progress.clone();
        s.set(
            "progress",
            lua.create_function(move |_, v: i32| {
                p.world_gen.store(v, Ordering::Relaxed);
                Ok(())
            })?,
        )?;
        let newgame: Table = lua.load("return require('engine.newgame')").eval()?;
        let generate: mlua::Function = newgame.get("generate")?;
        let dir = game_dir.replace('\\', "/");
        let game: Table = generate.call((dir.clone(), s))?;
        newgame.set("last", game.clone())?;
        let summary: String = game.get("summary")?;
        let t1 = t0.elapsed().as_secs_f64();
        // InitPostGalaxyCreation's part of the bar
        progress.stage.store(POST, Ordering::Relaxed);
        let engine: Table = lua.load("return require('engine')").eval()?;
        let load: mlua::Function = engine.get("load")?;
        let tree: Table = game.get("tree")?;
        game.set("tree", mlua::Value::Nil)?;
        if std::env::var("STELLAR_NEWGAME_CHECK").as_deref() == Ok("1") {
            let check: mlua::Function = lua.load(TREE_CHECK).eval()?;
            let r: String = check.call(tree.clone())?;
            eprintln!("{r}");
        }
        // STELLAR_NEWGAME_TEXT=1: the world from the tree's text, as a save would give it
        let loaded: String = if std::env::var("STELLAR_NEWGAME_TEXT").as_deref() == Ok("1") {
            let text: mlua::String = lua.load("return require('engine.newgame.save').write(...)").call(tree)?;
            load.call((dir, text))?
        } else {
            load.call((dir, tree))?
        };
        let t2 = t0.elapsed().as_secs_f64();
        let start_script: mlua::Function = newgame.get("start_script")?;
        let script: String = start_script.call(game)?;
        // InitPostGalaxyCreation's terra incognita: the maps, cleared in sensor range
        let post: String = lua.load("return require('engine.newgame.post').run()").eval()?;
        Ok(format!(
            "{summary}\n{loaded}\n{script}\n{post}\nnew game: generated in {t1:.1} s, loaded in {:.1} s, started in {:.1} s",
            t2 - t1,
            t0.elapsed().as_secs_f64() - t2
        ))
    };
    let report = run().map_err(|e| format!("new game: {e}"))?;
    let path = format!("{}/?.lua", crate::galaxy::lua_dir());
    let package: Table = runtime.lua.globals().get("package").map_err(|e| e.to_string())?;
    let old: String = package.get("path").map_err(|e| e.to_string())?;
    package.set("path", format!("{path};{old}")).map_err(|e| e.to_string())?;
    Ok((runtime, report))
}

/// STELLAR_NEWGAME_CHECK=1: the generated tree against its own text parsed again (what a save
/// round trip would give the world): the first differences of shape, tokens and shared tables.
const TREE_CHECK: &str = r#"
return function(tree)
    local save, pdxscript = require('engine.newgame.save'), require('pdxscript')
    local parsed = assert(pdxscript.parse(save.write(tree), 'gamestate'))
    local out, seen, n = {}, {}, 0
    local function note(s) n = n + 1 if n <= 40 then out[#out + 1] = s end end
    local function walk(a, b, path)
        if type(a) ~= type(b) then note(path .. ': ' .. type(a) .. ' vs ' .. type(b)) return end
        if type(a) ~= 'table' then
            if a ~= b then note(path .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end
            return
        end
        if seen[a] then note(path .. ': shared with ' .. seen[a]) return end
        seen[a] = path
        for k, v in pairs(b) do
            -- the parser's positions are not the world's
            if a[k] == nil and k ~= 'line' and k ~= 'last' and k ~= 'warnings' then note(path .. '.' .. tostring(k) .. ': missing (parsed ' .. tostring(v) .. ')') end
        end
        for k, v in pairs(a) do
            if k == 'line' or k == 'last' then
            elseif b[k] == nil then note(path .. '.' .. tostring(k) .. ': extra ' .. tostring(v))
            else walk(v, b[k], path .. '.' .. tostring(k)) end
        end
    end
    walk(tree, parsed, 'gamestate')
    return string.format('tree check: %d differences\n%s', n, table.concat(out, '\n'))
end
"#;

/// The load screen's bar as the game moves it: the stages' progress context states and the
/// smoothing of LaunchNewGame's loop, stepped every 16 ms.
#[derive(Clone, Debug, Default)]
pub struct Bar {
    /// the bar shown (LaunchNewGame's float)
    pub shown: f32,
    /// the 16 ms steps not run yet (s)
    pending: f32,
}

/// One state of the progress context: { start, span } on the whole bar.
fn transformed(state: (i32, i32), p: i32) -> i32 {
    state.0 + state.1 * p / 100
}

/// The progress context's top state in a stage of the generation: LaunchNewGame's (0, 50), then
/// GenerateNewGalaxy's (0, 75) or InitPostGalaxyCreation's (75, 100) in it.
pub fn state_of(stage: u8) -> (i32, i32) {
    let push = |s: (i32, i32), a: i32, b: i32| (s.0 + s.1 * a / 100, s.1 * (b - a) / 100);
    let launch = push((0, 100), 0, 50);
    if stage == GENERATING {
        push(launch, 0, 75)
    } else {
        push(launch, 75, 100)
    }
}

impl Bar {
    /// `dt` seconds pass while the generation runs at `progress` in `stage`: LaunchNewGame's
    /// steps, one each 16 ms. Whether the bar drawn (its whole percent) changed.
    pub fn advance(&mut self, dt: f32, stage: u8, progress: i32) -> bool {
        let before = self.shown as i32;
        self.pending += dt;
        while self.pending >= 0.016 {
            self.pending -= 0.016;
            // the bar is compared with the progress itself, not with its transform **[V]**
            if self.shown != progress as f32 {
                self.shown = self.shown * 0.9 + 0.1 * transformed(state_of(stage), progress) as f32;
            }
        }
        self.shown as i32 != before
    }

    /// The whole percent drawn.
    pub fn percent(&self) -> i32 {
        self.shown as i32
    }
}

/// The bar in RestoreDeviceObjects (`LOAD_MAP_GFX`): its step `k` of 100 on its state (50, 75).
pub fn map_gfx_percent(k: i32) -> i32 {
    transformed((50, 25), k)
}

/// The background picture: one of gfx/loadingscreens/*.dds (CGameGraphics::LoadLoadingScreens
/// draws one with a CCrudeRandom seeded from the clock; the files in the order the folder lists
/// them [I]), here by `seed`.
pub fn background(game_dir: &str, seed: u64) -> Option<String> {
    let dir = std::path::Path::new(game_dir).join("gfx/loadingscreens");
    let mut files: Vec<String> = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.to_lowercase().ends_with(".dds"))
        .collect();
    files.sort_by_key(|n| n.to_lowercase());
    if files.is_empty() {
        return None;
    }
    Some(format!("gfx/loadingscreens/{}", files[(seed % files.len() as u64) as usize]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_settings() {
        let s = NewGameSettings::parse(&["scenario=tiny", "empires=3", "seed=1234", "empire=humans1"]).unwrap();
        assert_eq!(s.get("scenario"), Some("tiny"));
        assert_eq!(s.global_seed(), 0);
        assert_eq!(s.empire.as_deref(), Some("humans1"));
        assert!(NewGameSettings::parse(&["galaxy_size=tiny"]).is_err());
        assert!(NewGameSettings::parse(&["tiny"]).is_err());
    }

    #[test]
    fn progress_states() {
        // LaunchNewGame (0, 50), GenerateNewGalaxy (0, 75) -> {0, 37}; InitPostGalaxyCreation
        // (75, 100) -> {37, 12}
        assert_eq!(state_of(GENERATING), (0, 37));
        assert_eq!(state_of(POST), (37, 12));
        assert_eq!(transformed(state_of(GENERATING), 70), 25);
        assert_eq!(map_gfx_percent(100), 75);
    }

    #[test]
    fn bar_approaches() {
        let mut b = Bar::default();
        b.advance(1.0, GENERATING, 100);
        // 62 steps toward 37
        assert!(b.percent() >= 36 && b.percent() <= 37, "{}", b.percent());
        let mut c = Bar::default();
        c.advance(0.010, GENERATING, 100);
        assert_eq!(c.shown, 0.0);
    }
}
