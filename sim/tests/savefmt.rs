//! Saves as the game writes them (engine/savegame.lua, docs/saves.md): the format round trip.
//!
//! - a sample in the game's layout: read, written, read again gives the same tree and the same
//!   bytes (no game, no save needed);
//! - a save's zip written and read back;
//! - with a save the game wrote (save::default_save, STELLAR_SAVE): its gamestate and meta read,
//!   written in the game's layout and compared with the game's own bytes.

use stellar_sim::{save, Date, Runtime};

/// The game's layout, every rule the writer follows (4.5.2's own saves): `key=value`, blocks on the
/// next line, an empty block, unquoted values on one line with a space after each, quoted values
/// one per line, a run of blocks without keys (an indent-only line before, a one-space line after
/// each), the inline `random={ a b }`, a store with a `none` slot.
const SAMPLE: &str = "version=\"Cygnus v4.5.2\"
version_control_revision=101
name=\"United Nations of Earth\"
date=\"2210.01.01\"
required_dlcs=
{
\t\"Ancient Relics Story Pack\"
\t\"Federations\"
}
player=
{
\t
\t{
\t\tname=\"unknown\"
\t\tcountry=0
\t}
\x20
}
tick=4
species_db=
{
\t0=
\t{
\t\ttraits=
\t\t{
\t\t}
\t\thome_planet=
\t\t{
\t\t\ttype=planet
\t\t\treference=4294967295
\t\t}
\t\tformed=\t\t\"2209.04.19\"
\t\tdismantle_finish_date=\"2213.06.18\"
\t\tlast_valid_resource_targets=
\t\t{
\t\t\t\t\t\t\"2213.06.18\"
\t\t\t\"2213.06.19\"
\t\t}
\t}
}
galactic_object=
{
\t0=
\t{
\t\tcoordinate=
\t\t{
\t\t\tx=-131.97
\t\t\ty=-90.15
\t\t\tvisual_height=3.65056
\t\t}
\t\thyperlane=
\t\t{
\t\t\t
\t\t\t{
\t\t\t\tto=57
\t\t\t\tlength=37
\t\t\t}
\x20
\t\t\t{
\t\t\t\tto=79
\t\t\t\tlength=36
\t\t\t}
\x20
\t\t}
\t\tfleet_presence=
\t\t{
\t\t\t4 5 6 7\x20
\t\t}
\t\tai=
\t\t{
\t\t\trandom={ 0 633261057 }
\t\t}
\t}
\t1=none
}
random_seed=-386941723
random_count=14059548
";

fn runtime() -> Runtime {
    Runtime::new(Date::from_ymd(2210, 1, 1), 0).expect("the Lua runtime")
}

/// `chunk` run with `text` as the global TEXT; what it returns.
fn with_text(rt: &Runtime, text: &str, chunk: &str) -> String {
    rt.lua.globals().set("TEXT", rt.lua.create_string(text).unwrap()).unwrap();
    rt.eval::<String>(chunk).unwrap_or_else(|e| panic!("{e}"))
}

const ROUND_TRIP: &str = r#"
    local pdxscript = require("pdxscript")
    local savegame = require("engine.savegame")
    local tree = assert(pdxscript.parse(TEXT, "gamestate"))
    local text = savegame.write(tree)
    local again = assert(pdxscript.parse(text, "gamestate"))
    local same = pdxscript.write(tree) == pdxscript.write(again)
    return (same and "same tree" or "the tree changed") .. "\n" .. text
"#;

#[test]
fn the_game_layout_reads_and_writes_back_the_same() {
    let rt = runtime();
    let out = with_text(&rt, SAMPLE, ROUND_TRIP);
    let (verdict, text) = out.split_once('\n').unwrap();
    assert_eq!(verdict, "same tree");
    assert_eq!(text, SAMPLE, "the game's layout written back byte for byte");
}

#[test]
fn the_head_is_set_from_the_simulation() {
    let rt = runtime();
    rt.load_world(SAMPLE).expect("load_world");
    let text: String = rt
        .eval(
            r#"
            local savegame = require("engine.savegame")
            savegame.prepare({ date = "2210.02.01", tick = 0, seed = 3908025573, position = 14059660 })
            return savegame.write(require("engine.world").tree)
            "#,
        )
        .unwrap();
    assert!(text.contains("\ndate=\"2210.02.01\"\n"), "date");
    assert!(text.contains("\ntick=0\n"), "tick");
    // the seed, a u32, written as the game's signed int
    assert!(text.contains("\nrandom_seed=-386941723\n"), "seed");
    assert!(text.contains("\nrandom_count=14059660\n"), "position");
    assert_eq!(save::random_of(&text), Some((3908025573, 14059660)));
    assert_eq!(save::tick_of(&text), Some(0));
}

#[test]
fn the_save_folder_is_named_as_the_game_names_it() {
    // the user's folder, made by the game [V]
    assert_eq!(save::save_folder_name("Sacred Uthabulan Order"), "sacreduthabulanorder_-730439522");
    // nothing removed: no hash
    assert_eq!(save::save_folder_name("Humans1"), "humans1");
    assert_eq!(save::save_file_name("2210.01.01"), "2210.01.01.sav");
    assert_eq!(save::save_file_name("a/b:c?"), "abc.sav");
}

#[test]
fn a_zip_written_reads_back() {
    let out = std::env::temp_dir().join("stellar_savefmt_zip.sav");
    let out = out.to_str().unwrap();
    let meta = "version=\"Cygnus v4.5.2\"\ndate=\"2210.01.01\"\n";
    save::write_save(out, SAMPLE, meta, "2210.01.01").expect("write");
    assert_eq!(save::read_gamestate(out).unwrap(), SAMPLE);
    assert_eq!(save::read_meta(out).unwrap(), meta);
    // the game's entry order and times: gamestate first, then meta, DOS time 0 [V 4.5.2's saves]
    let mut z = zip::ZipArchive::new(std::fs::File::open(out).unwrap()).unwrap();
    assert_eq!(z.by_index(0).unwrap().name(), "gamestate");
    assert_eq!(z.by_index(1).unwrap().name(), "meta");
    assert_eq!(z.by_index(0).unwrap().compression(), zip::CompressionMethod::Deflated);
    let _ = std::fs::remove_file(out);
}

/// The lines of `a` and `b` that the other does not have (as multisets): a diff's size without
/// the diff.
fn lines_apart(a: &str, b: &str) -> usize {
    let mut count: std::collections::HashMap<&str, i64> = std::collections::HashMap::new();
    for l in a.lines() {
        *count.entry(l).or_default() += 1;
    }
    for l in b.lines() {
        *count.entry(l).or_default() -= 1;
    }
    count.values().map(|v| v.unsigned_abs() as usize).sum()
}

/// The game's own save, read and written in the game's layout: the same tree, nearly the same
/// lines (the member writers' layouts the tree does not keep, savegame.lua), the same meta.
#[test]
fn a_save_the_game_wrote_is_written_back_as_the_game_wrote_it() {
    let Some(path) = save::default_save() else {
        eprintln!("skipped: no save");
        return;
    };
    let gamestate = save::read_gamestate(&path).expect("gamestate");
    let meta = save::read_meta(&path).expect("meta");
    let rt = runtime();
    let out = with_text(&rt, &gamestate, ROUND_TRIP);
    let (verdict, text) = out.split_once('\n').unwrap();
    assert_eq!(verdict, "same tree");
    let apart = lines_apart(&gamestate, text);
    let lines = gamestate.lines().count();
    println!("{path}: {lines} lines, {apart} written in another layout ({:.3}%)", apart as f64 * 100.0 / lines as f64);
    if apart * 1000 > lines {
        let dump = std::env::temp_dir().join("stellar_savefmt_written.gamestate");
        let _ = std::fs::write(&dump, text);
        panic!("{apart} of {lines} lines in another layout than the game's (written: {})", dump.display());
    }
    // the meta made from the world, against the game's
    rt.load_world(&gamestate).expect("load_world");
    rt.lua.globals().set("OLD", meta.as_str()).unwrap();
    let made: String = rt.eval("return require('engine.savegame').meta(nil)").unwrap();
    assert_eq!(made, meta, "the meta made from the world");
    let kept: String = rt.eval("return require('engine.savegame').meta(OLD)").unwrap();
    assert_eq!(kept, meta, "the meta made from the world and the old meta");
}
