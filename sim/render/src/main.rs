//! stellar-render: the galaxy map of a save drawn with the game's own art, and the main screen's
//! top bar from the game's GUI files, with wgpu on Vulkan.
//!
//! The save's world is loaded through the Lua runtime (`stellar_sim::Runtime::load_world`); the
//! map (systems, star classes, hyperlanes, owners and their colours) is read from it with
//! `lua/render/galaxy.lua`, the sprites and fonts of the .gfx files with `lua/render/gfx.lua`,
//! and the top bar of interface/main.gui is laid out and bound to the player's country with
//! `lua/render/gui.lua` and `lua/render/topbar.lua`. Textures are the game's .dds files, read in
//! place.
//!
//!   cargo run --release -p stellar-render -- --png out.png    # offscreen, to a PNG, checked
//!   cargo run --release -p stellar-render                     # in a window
//!
//! Options: --save SAVE.sav (default STELLAR_SAVE, the 2210.01.01 autosave),
//! --game DIR (default STELLARIS_DIR, the Steam install, /opt/stellaris), --size WxH (PNG,
//! default 2048x2048), --adapter NAME (a Vulkan adapter whose name contains NAME, e.g.
//! llvmpipe), --frames N (window: close after N frames), --dds OUT_DIR FILE.dds... (decode
//! textures to PNGs and print their formats), --dds-check DIR... (decode every .dds under the
//! directories and count them by format).

mod border;
mod dds;
mod font;
mod galaxy;
mod gui;
mod render;
mod scene;
mod verify;
mod window;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use stellar_sim::{save, Runtime};

use crate::border::Borders;
use crate::dds::{Cache, Image};
use crate::font::Font;
use crate::galaxy::Galaxy;
use crate::gui::Topbar;
use crate::scene::{Scene, Textures, ALL, LAYERS};

/// The map of a save: the world in its runtime, the galaxy read from it, the borders, and the
/// game's textures and fonts as they are loaded.
pub struct Map {
    pub runtime: Runtime,
    pub game_dir: String,
    pub galaxy: Galaxy,
    pub borders: Borders,
    pub cache: Rc<RefCell<Cache>>,
    pub textures: Textures,
    pub borders_texture: usize,
    pub fonts: Option<HashMap<String, Font>>,
}

/// One frame's content for a target size.
pub struct Frame {
    pub scene: Scene,
    pub topbar: Topbar,
}

impl Map {
    pub fn load(game_dir: &str, save_path: &str) -> Result<Map, String> {
        let runtime = galaxy::runtime(save_path)?;
        let galaxy = galaxy::extract(&runtime, game_dir)?;
        let t0 = std::time::Instant::now();
        let borders = border::compute(&galaxy);
        eprintln!("borders: {}x{} texels of {:.2} map units in {:.2} s", borders.width, borders.height, borders.texel, t0.elapsed().as_secs_f64());
        let mut textures = Textures::default();
        let img = Image { width: borders.width, height: borders.height, rgba: borders.rgba.clone(), format: "generated".into() };
        let borders_texture = textures.add("@borders", Arc::new(img));
        Ok(Map {
            runtime,
            game_dir: game_dir.to_string(),
            galaxy,
            borders,
            cache: Rc::new(RefCell::new(Cache::default())),
            textures,
            borders_texture,
            fonts: None,
        })
    }

    /// The scene for a target of `width` x `height` (the top bar is laid out for that screen).
    pub fn frame(&mut self, width: u32, height: u32) -> Result<Frame, String> {
        let topbar = gui::topbar(&self.runtime, &self.game_dir, &self.cache, width, height)?;
        if self.fonts.is_none() {
            self.fonts = Some(gui::fonts(&self.runtime, &self.game_dir, &topbar)?);
        }
        let inputs = scene::Inputs {
            galaxy: &self.galaxy,
            borders: &self.borders,
            borders_texture: self.borders_texture,
            topbar: &topbar,
            fonts: self.fonts.as_ref().unwrap(),
            game_dir: &self.game_dir,
        };
        let scene = scene::build(&inputs, &mut self.textures, &mut self.cache.borrow_mut(), width, height);
        Ok(Frame { scene, topbar })
    }
}

struct Args {
    png: Option<String>,
    save: Option<String>,
    game: Option<String>,
    size: (u32, u32),
    adapter: Option<String>,
    frames: Option<u32>,
}

fn usage() -> ! {
    eprintln!(
        "usage: stellar-render [--png OUT.png] [--size WxH] [--save SAVE.sav] [--game STELLARIS_DIR] \
         [--adapter NAME] [--frames N] | --dds OUT_DIR FILE.dds..."
    );
    std::process::exit(2)
}

fn parse_args() -> Args {
    let mut a = Args { png: None, save: None, game: None, size: (2048, 2048), adapter: None, frames: None };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let mut value = || it.next().unwrap_or_else(|| usage());
        match arg.as_str() {
            "--png" => a.png = Some(value()),
            "--save" => a.save = Some(value()),
            "--game" => a.game = Some(value()),
            "--adapter" => a.adapter = Some(value()),
            "--frames" => a.frames = Some(value().parse().unwrap_or_else(|_| usage())),
            "--size" => {
                let v = value();
                let (w, h) = v.split_once('x').unwrap_or_else(|| usage());
                a.size = (w.parse().unwrap_or_else(|_| usage()), h.parse().unwrap_or_else(|_| usage()));
            }
            _ => usage(),
        }
    }
    a
}

fn hex(c: [f32; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", (c[0] * 255.0).round() as u8, (c[1] * 255.0).round() as u8, (c[2] * 255.0).round() as u8)
}

/// Decodes every .dds under the given directories (in parallel) and counts them by format, with
/// the files that do not decode.
fn dds_check(dirs: &[String]) {
    fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("dds")) {
                out.push(p);
            }
        }
    }
    let mut files = Vec::new();
    for d in dirs {
        walk(std::path::Path::new(d), &mut files);
    }
    let t0 = std::time::Instant::now();
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
    let chunk = files.len().div_ceil(threads).max(1);
    let results: Vec<(String, Result<String, String>)> = std::thread::scope(|s| {
        let handles: Vec<_> = files
            .chunks(chunk)
            .map(|part| {
                s.spawn(move || {
                    part.iter()
                        .map(|p| {
                            let path = p.to_string_lossy().into_owned();
                            let r = dds::load(&path).map(|i| i.format);
                            (path, r)
                        })
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect()
    });
    let mut by_format: std::collections::BTreeMap<String, usize> = Default::default();
    let mut failed = Vec::new();
    for (path, r) in &results {
        match r {
            Ok(f) => *by_format.entry(f.clone()).or_default() += 1,
            Err(e) => failed.push(format!("{path}: {e}")),
        }
    }
    println!("{} .dds files decoded in {:.1} s on {threads} threads; {} failed", results.len() - failed.len(), t0.elapsed().as_secs_f64(), failed.len());
    for (f, n) in by_format {
        println!("  {n:>6} {f}");
    }
    for f in failed.iter().take(20) {
        println!("  failed: {f}");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--dds-check") {
        dds_check(&args[2..]);
        return;
    }
    if args.get(1).map(String::as_str) == Some("--dds") {
        if args.len() < 4 {
            usage();
        }
        for f in &args[3..] {
            match dds::load(f) {
                Ok(i) => {
                    let name = std::path::Path::new(f).file_stem().unwrap_or_default().to_string_lossy().to_string();
                    let out = format!("{}/{}.png", args[2], name);
                    match verify::write_png(&out, i.width, i.height, &i.rgba) {
                        Ok(()) => println!("{f}: {}x{} {} -> {out}", i.width, i.height, i.format),
                        Err(e) => println!("{f}: {e}"),
                    }
                }
                Err(e) => println!("{f}: {e}"),
            }
        }
        return;
    }
    if let Err(e) = run() {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = parse_args();
    let game = args.game.clone().or_else(save::game_dir).ok_or("no Stellaris install: set STELLARIS_DIR or give --game")?;
    let save = args.save.clone().or_else(save::default_save).ok_or("no save: give --save or set STELLAR_SAVE")?;
    println!("game: {game}\nsave: {save}");
    let mut map = Map::load(&game, &save)?;
    let g = &map.galaxy;
    let owned = g.systems.iter().filter(|s| s.owner.is_some()).count();
    println!("galaxy {}: {} systems, {} hyperlanes, {} owners of {} systems", g.date, g.systems.len(), g.lanes.len(), g.countries.len(), owned);
    println!("lua: {}", g.notes);

    let Some(png) = args.png.clone() else {
        return window::run(map, args.adapter, args.frames);
    };

    let (w, h) = args.size;
    let t0 = std::time::Instant::now();
    let frame = map.frame(w, h)?;
    println!("scene built in {:.2} s", t0.elapsed().as_secs_f64());
    println!("gfx: {}", frame.topbar.gfx_summary);
    let off = render::Offscreen::new(args.adapter.as_deref())?;
    let mut off = off;
    off.renderer.upload(&off.device, &off.queue, &frame.scene, &map.textures);
    let t1 = std::time::Instant::now();
    let full = off.render(w, h, ALL)?;
    println!("rendered {w}x{h} in {:.0} ms on: {}", t1.elapsed().as_secs_f64() * 1000.0, off.adapter);
    verify::write_png(&png, w, h, &full)?;
    drop(full);
    println!("wrote {png}");
    let mut without = HashMap::new();
    for l in LAYERS {
        without.insert(l, off.render(w, h, ALL & !l.bit())?);
    }

    // what was loaded
    let cache = map.cache.borrow();
    let formats: Vec<String> = cache.formats().iter().map(|(f, n)| format!("{f} {n}")).collect();
    let mut texture_formats: HashMap<String, usize> = HashMap::new();
    for i in &map.textures.images {
        *texture_formats.entry(i.format.clone()).or_default() += 1;
    }
    println!("dds: {} files decoded ({}); textures drawn: {}", cache.images.len(), formats.join(", "), map.textures.names.len());
    for m in &map.textures.missing {
        println!("  texture not loaded: {m}");
    }
    let bar = &frame.topbar;
    if !bar.missing.is_empty() {
        println!("  gui sprites without a definition or texture: {}", bar.missing.join(", "));
    }
    let skipped: Vec<String> = bar.skipped.iter().map(|(k, n)| format!("{k} {n}")).collect();
    println!("gui: {} sprites, {} texts laid out; element kinds not drawn: {}", frame.scene.sprites.len(), frame.scene.texts.len(), skipped.join(", "));
    let fonts = map.fonts.as_ref().unwrap();
    for f in fonts.values() {
        println!("font {}: bitmap font {}.fnt, {} glyphs, line height {}, page {} ({}x{} {})", f.name, f.texture.trim_end_matches(".dds"), f.glyphs.len(), f.line_height, f.texture, f.image.width, f.image.height, f.image.format);
    }

    // read the PNG back and check it
    let frames = verify::Frames { width: w, height: h, without: &without };
    let c = verify::check(&png, &frames, &frame.scene, &map.galaxy, &map.borders, bar, fonts)?;
    let total = (c.width * c.height) as usize;
    println!("png read back: {}x{} = {total} pixels", c.width, c.height);
    for (l, n) in &c.changed {
        println!("  layer {:<10} changes {n:>8} pixels ({:.1}%)", format!("{l:?}"), 100.0 * *n as f64 / total as f64);
    }
    println!("  stars: {}/{} star sprites drawn (pixels changed inside each sprite's rectangle)", c.stars_ok, c.stars);
    println!("  lanes: {}/{} hyperlanes drawn at their middle", c.lanes_ok, c.lanes);
    println!("  borders, per owner: territory pixels changed; in the fill, pixels where the border shows that changed and");
    println!("  the mean error against the predicted colour (0..255); the edge band's mean colour vs its first colour x 0.9:");
    let g = &map.galaxy;
    let mut owners: Vec<&verify::OwnerCheck> = c.owners.iter().collect();
    owners.sort_by_key(|o| std::cmp::Reverse(o.pixels));
    for o in owners {
        let k = &g.countries[o.country];
        println!(
            "    {:>8} {:<36} {:>2} sys {:>6}/{:<6} px  fill {:>6}/{:<6} err {:.2}  edge {} vs {} ({}) err {:.0}",
            k.id,
            k.name,
            k.systems,
            o.changed,
            o.pixels,
            o.fill_visible_changed,
            o.fill_visible,
            o.fill_error,
            hex(o.edge_mean.map(|v| v / 255.0)),
            hex(k.primary),
            k.colour_names[0],
            o.edge_error,
        );
    }
    println!("  gui: {}/{} sprites with visible texels drawn ({} laid out)", c.sprites_ok, c.sprites_visible, c.sprites);
    for m in &c.sprites_missing {
        println!("    not seen: {m}");
    }
    println!("  top bar texts read back from the pixels (element, expected from the save, read, match score, source):");
    for t in &c.texts {
        println!(
            "    {:<44} {:>10} {:>10} {:.2} {} {}",
            t.path,
            t.expected,
            t.read,
            t.score,
            if t.read == t.expected { "ok" } else { "MISMATCH" },
            t.source
        );
    }
    let ok = c.ok();
    println!("check: {}", if ok { "ok" } else { "FAILED" });
    if !ok {
        return Err("the PNG does not show the map as drawn".into());
    }
    Ok(())
}
