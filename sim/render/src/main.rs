//! stellar-render: the galaxy map of a save, drawn with wgpu on Vulkan.
//!
//! The game's files and the save are loaded through the Lua runtime (`stellar_sim::Runtime`); the
//! map (systems, hyperlanes, owners and their colours) is read from its world with the query in
//! `lua/render/galaxy.lua`.
//!
//!   cargo run --release -p stellar-render -- --png out.png    # offscreen, to a PNG, checked
//!   cargo run --release -p stellar-render                     # in a window
//!
//! Options: --save SAVE.sav (default STELLAR_SAVE, the 2210.01.01 autosave),
//! --game DIR (default STELLARIS_DIR, the Steam install, /opt/stellaris), --size WxH (PNG,
//! default 2048x2048), --adapter NAME (a Vulkan adapter whose name contains NAME, e.g.
//! llvmpipe), --frames N (window: close after N frames).

mod galaxy;
mod render;
mod verify;
mod window;

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
         [--adapter NAME] [--frames N]"
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

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = parse_args();
    let game = args.game.clone().or_else(galaxy::default_game_dir).ok_or("no Stellaris install: set STELLARIS_DIR or give --game")?;
    let save = args.save.clone().or_else(galaxy::default_save).ok_or("no save: give --save or set STELLAR_SAVE")?;
    println!("game: {game}\nsave: {save}");
    let g = galaxy::load(&game, &save)?;
    let owned = g.systems.iter().filter(|s| s.owner.is_some()).count();
    println!("galaxy {}: {} systems, {} hyperlanes, {} owners of {} systems", g.date, g.systems.len(), g.lanes.len(), g.countries.len(), owned);
    println!("lua: {}", g.notes);

    let Some(png) = args.png.clone() else {
        return window::run(g, args.adapter, args.frames);
    };

    let (w, h) = args.size;
    let (pixels, layout, device) = render::render_offscreen(&g, w, h, args.adapter.as_deref())?;
    verify::write_png(&png, w, h, &pixels)?;
    drop(pixels);
    println!("wrote {png} ({w}x{h}); device: {device}");
    println!(
        "layout: {:.3} px per map unit; star radius {:.1} px (unowned {:.1}), lane width {:.1} px",
        layout.scale, layout.star_radius, layout.unowned_radius, layout.lane_width
    );

    // read the PNG back and check it
    let style = render::Style::default();
    let c = verify::check(&png, &g, &layout, &style)?;
    let total = (c.width * c.height) as usize;
    println!("png read back: {}x{} = {total} pixels", c.width, c.height);
    println!(
        "  background {} ({:.1}%), owner colours {} (in {} distinct colours), unowned grey {}, lane colour {}, edges and blends {}",
        c.background,
        100.0 * c.background as f64 / total as f64,
        c.coloured,
        c.colours,
        c.unowned,
        c.lane,
        c.other
    );
    println!(
        "  drawn area: x {}..{}, y {}..{} ({}x{} px)",
        c.bbox.0,
        c.bbox.2,
        c.bbox.1,
        c.bbox.3,
        c.bbox.2.saturating_sub(c.bbox.0) + 1,
        c.bbox.3.saturating_sub(c.bbox.1) + 1
    );
    println!(
        "  systems: {}/{} drawn at their position with the expected colour ({} showing their own colour, the rest under a neighbour's disc)",
        c.systems_ok, c.systems, c.systems_own_colour
    );
    println!(
        "  lanes: {}/{} drawn at their middle ({} of {} lanes have a middle clear of discs)",
        c.lanes_ok, c.lanes_checked, c.lanes_checked, c.lanes
    );
    println!("  owners visible: {}/{} have pixels of their colour", c.countries_visible, g.countries.len());
    let mut by_size: Vec<usize> = (0..g.countries.len()).collect();
    by_size.sort_by_key(|&i| std::cmp::Reverse(g.countries[i].systems));
    println!("  owners (country id, name key, type, colour name, its colour and source, drawn colour, systems, pixels of the colour):");
    for i in by_size {
        let k = &g.countries[i];
        println!(
            "    {:>8} {:<26} {:<17} {:<12} {} ({:<5}) {} {:>3} systems {:>6} px",
            k.id,
            k.name,
            k.kind,
            k.colour_name,
            hex(k.rgb),
            k.colour_source,
            hex(style.owner_colour(k.rgb)),
            k.systems,
            c.per_country[i]
        );
    }
    let ok = c.systems_ok == c.systems && c.lanes_ok == c.lanes_checked && c.countries_visible == g.countries.len();
    println!("check: {}", if ok { "ok" } else { "FAILED" });
    if !ok {
        return Err("the PNG does not show the map as drawn".into());
    }
    Ok(())
}
