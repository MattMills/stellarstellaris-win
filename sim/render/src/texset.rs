//! The textures a game can show (lua/render/texture_set.lua), by what shows them, with what they
//! cost on the disk, on the GPU compressed and decoded (docs/profiling.md section 13).

use std::collections::{BTreeMap, BTreeSet};

/// A DDS file's header: its size, mip levels and pixel format (the file is not read further).
#[derive(Clone, Debug)]
pub struct DdsInfo {
    pub width: u32,
    pub height: u32,
    pub mips: u32,
    /// a block-compressed format's name (`BC1`..`BC7`) or `RGBA8`-like for uncompressed ones
    pub format: String,
    /// bytes a texel block of the format takes (BC1/BC4: 8 a 4x4 block; BC2/3/5/6/7: 16), 0 for
    /// uncompressed (then `bits` a pixel)
    pub block: u32,
    pub bits: u32,
    pub cube: bool,
}

impl DdsInfo {
    /// The bytes of its mip chain uploaded as it is in the file (compressed blocks, or the pixels).
    pub fn gpu_bytes(&self) -> u64 {
        let mut sum = 0u64;
        for m in 0..self.mips.max(1) {
            let (w, h) = ((self.width >> m).max(1) as u64, (self.height >> m).max(1) as u64);
            sum += if self.block > 0 { w.div_ceil(4) * h.div_ceil(4) * self.block as u64 } else { w * h * self.bits.max(32) as u64 / 8 };
        }
        sum * if self.cube { 6 } else { 1 }
    }

    /// The bytes decoded to RGBA8 with a full mip chain (the renderer's way now).
    pub fn rgba_bytes(&self) -> u64 {
        (self.width as u64 * self.height as u64 * 4 * 4 / 3) * if self.cube { 6 } else { 1 }
    }
}

/// The header of a DDS file (None: not one, or unreadable).
pub fn dds_info(path: &str) -> Option<DdsInfo> {
    use std::io::Read;
    let mut f = std::fs::File::open(path).ok()?;
    let mut h = [0u8; 148];
    let n = f.read(&mut h).ok()?;
    if n < 128 || &h[0..4] != b"DDS " {
        return None;
    }
    let u = |o: usize| u32::from_le_bytes([h[o], h[o + 1], h[o + 2], h[o + 3]]);
    let (height, width, mips) = (u(12), u(16), u(28));
    let pf_flags = u(80);
    let fourcc = &h[84..88];
    let bits = u(88);
    let caps2 = u(112);
    let cube = caps2 & 0x200 != 0;
    let (format, block) = if pf_flags & 0x4 != 0 {
        match fourcc {
            b"DXT1" => ("BC1".to_string(), 8),
            b"DXT2" | b"DXT3" => ("BC2".to_string(), 16),
            b"DXT4" | b"DXT5" => ("BC3".to_string(), 16),
            b"ATI1" | b"BC4U" | b"BC4S" => ("BC4".to_string(), 8),
            b"ATI2" | b"BC5U" | b"BC5S" => ("BC5".to_string(), 16),
            b"DX10" if n >= 148 => {
                let dxgi = u(128);
                match dxgi {
                    70..=72 => ("BC1".to_string(), 8),
                    73..=75 => ("BC2".to_string(), 16),
                    76..=78 => ("BC3".to_string(), 16),
                    79..=81 => ("BC4".to_string(), 8),
                    82..=84 => ("BC5".to_string(), 16),
                    94..=96 => ("BC6H".to_string(), 16),
                    97..=99 => ("BC7".to_string(), 16),
                    d => (format!("DXGI {d}"), 0),
                }
            }
            other => (format!("fourcc {}", String::from_utf8_lossy(other)), 0),
        }
    } else {
        (format!("uncompressed {bits} bits"), 0)
    };
    Some(DdsInfo { width, height, mips: mips.max(1), format, block, bits, cube })
}

/// A set's sum: files, bytes on the disk, uploaded compressed, decoded RGBA; by format.
#[derive(Default)]
pub struct Sum {
    pub files: usize,
    pub missing: usize,
    pub disk: u64,
    pub gpu: u64,
    pub rgba: u64,
    pub formats: BTreeMap<String, usize>,
}

impl Sum {
    pub fn add(&mut self, game_dir: &str, rel: &str) {
        // (a cube map's key: its file)
        let rel = rel.strip_prefix("cube").and_then(|r| r.split_once(':')).map_or(rel, |(_, p)| p);
        let tga_dds = rel.strip_suffix(".tga").map(|b| format!("{b}.dds"));
        let Some(path) = crate::dds::find_case_insensitive(game_dir, rel).or_else(|| tga_dds.as_ref().and_then(|d| crate::dds::find_case_insensitive(game_dir, d))) else {
            self.missing += 1;
            return;
        };
        self.files += 1;
        self.disk += std::fs::metadata(&path).map_or(0, |m| m.len());
        match dds_info(&path) {
            Some(i) => {
                self.gpu += i.gpu_bytes();
                self.rgba += i.rgba_bytes();
                *self.formats.entry(i.format.clone()).or_default() += 1;
            }
            None => {
                *self.formats.entry("not DDS (tga)".into()).or_default() += 1;
            }
        }
    }

    pub fn line(&self, name: &str) -> String {
        let mb = |b: u64| b as f64 / 1048576.0;
        let formats: Vec<String> = self.formats.iter().map(|(f, n)| format!("{f} {n}")).collect();
        format!(
            "{name}: {} files ({} not found), {:.0} MB on the disk, {:.0} MB on the GPU compressed, {:.0} MB decoded RGBA with mips; {}",
            self.files,
            self.missing,
            mb(self.disk),
            mb(self.gpu),
            mb(self.rgba),
            formats.join(", ")
        )
    }
}

/// The texture paths of models by name (their parts' textures, their attachments' too).
pub fn model_textures(lib: &mut crate::models::Library, rt: &stellar_sim::Runtime, game_dir: &str, names: &BTreeSet<String>, out: &mut BTreeSet<String>) -> usize {
    let mut failed = 0;
    let mut todo: Vec<String> = names.iter().cloned().collect();
    let mut done: BTreeSet<String> = BTreeSet::new();
    while let Some(n) = todo.pop() {
        if !done.insert(n.clone()) {
            continue;
        }
        match lib.model(rt, game_dir, &n) {
            Ok(m) => {
                for p in &m.parts {
                    for t in &p.textures {
                        if !t.is_empty() {
                            out.insert(t.clone());
                        }
                    }
                }
                for (_, e) in &m.attach {
                    todo.push(e.clone());
                }
            }
            Err(_) => failed += 1,
        }
    }
    failed
}

/// The textures of the worlds (gfx/worldgfx/*.txt): each `environment_map` a cube of 16 levels
/// (`cube16:PATH`), each `galaxy_background` texture a cube of one (`cube1:PATH`), the other
/// images they name (the colour corrections, the stars' surfaces) as they are.
pub fn world_textures(game_dir: &str) -> Vec<String> {
    let mut out = BTreeSet::new();
    let Ok(rd) = std::fs::read_dir(format!("{game_dir}/gfx/worldgfx")) else { return Vec::new() };
    for e in rd.flatten() {
        let p = e.path();
        if !p.extension().is_some_and(|x| x.eq_ignore_ascii_case("txt")) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        let mut rest = text.as_str();
        while let Some(q) = rest.find('"') {
            let after = &rest[q + 1..];
            let Some(end) = after.find('"') else { break };
            let value = &after[..end];
            let before = rest[..q].trim_end();
            let low = value.to_ascii_lowercase();
            if low.ends_with(".dds") || low.ends_with(".tga") {
                let key = if before.ends_with("environment_map =") || before.ends_with("environment_map=") {
                    format!("cube16:{value}")
                } else if before.ends_with("texture =") && text[..text.len() - rest.len() + q].rfind("galaxy_background").is_some_and(|g| text[g..text.len() - rest.len() + q].matches('}').count() == 0) {
                    format!("cube1:{value}")
                } else {
                    value.to_string()
                };
                out.insert(key);
            }
            rest = &after[end + 1..];
        }
    }
    out.into_iter().collect()
}

/// The textures the game can show (texture_set.lua), `(kind, path)` each once, in the order they
/// are read ahead: the planets' and stars', the portraits', the player's culture's ships', the
/// other ships', then (with `gui`) the GUI's sprites'; and the entities not resolved.
pub fn used(map: &mut crate::Map, front: &stellar_sim::Runtime, game_dir: &str, gui: bool) -> Result<(Vec<(String, String)>, usize), String> {
    let gd = game_dir.replace('\\', "/");
    let code = format!("return require('render.texture_set').world({gd:?}, {})", map.galaxy.player);
    let world = match map.clock.as_ref().filter(|c| c.status().ready) {
        Some(c) => c.query(&code)?,
        None => map.runtime.lua.load(&code).eval::<String>().map_err(|e| e.to_string())?,
    };
    let gui_lines = if gui { front.lua.load("return require('render.texture_set').gui()").eval::<String>().map_err(|e| e.to_string())? } else { String::new() };
    let mut culture = String::new();
    let mut entities: BTreeMap<&str, BTreeSet<String>> = BTreeMap::new();
    let mut paths: BTreeMap<&str, BTreeSet<String>> = BTreeMap::new();
    for line in world.lines().chain(gui_lines.lines()) {
        let Some((kind, name)) = line.split_once('\t') else { continue };
        match kind {
            "culture" => culture = format!("{name}_"),
            "ship" if !culture.is_empty() && name.starts_with(&culture) => {
                entities.entry("ship (the player's culture)").or_default().insert(name.to_string());
            }
            "ship" => {
                entities.entry("ship (other cultures)").or_default().insert(name.to_string());
            }
            "planet" => {
                entities.entry("planet").or_default().insert(name.to_string());
            }
            "portrait" => {
                entities.entry("portrait").or_default().insert(name.to_string());
            }
            "portrait_texture" => {
                paths.entry("portrait").or_default().insert(name.to_string());
            }
            "gui" => {
                paths.entry("gui").or_default().insert(name.to_string());
            }
            _ => {}
        }
    }
    map.warm();
    let mut failed = 0;
    for (kind, names) in &entities {
        let mut out = BTreeSet::new();
        failed += model_textures(&mut map.models, &map.runtime, game_dir, names, &mut out);
        paths.entry(kind).or_default().extend(out);
    }
    let mut list = Vec::new();
    let mut seen = BTreeSet::new();
    // the worlds' (gfx/worldgfx: the systems' and the designer's skies and reflections, their
    // colour corrections), as dds::Cache names them (a cube map `cubeN:PATH`)
    for key in world_textures(game_dir) {
        if seen.insert(key.clone()) {
            list.push(("world".to_string(), key));
        }
    }
    for kind in ["planet", "portrait", "ship (the player's culture)", "ship (other cultures)", "gui"] {
        for p in paths.get(kind).into_iter().flatten() {
            if seen.insert(p.clone()) {
                list.push((kind.to_string(), p.clone()));
            }
        }
    }
    Ok((list, failed))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A DDS file of `w` x `h`, `mips` levels, DXT1 or DXT5 (`fourcc`), cube or not, its blocks zeros.
    fn dds(w: u32, h: u32, mips: u32, fourcc: &[u8; 4], cube: bool) -> Vec<u8> {
        let mut b = vec![0u8; 128];
        b[0..4].copy_from_slice(b"DDS ");
        b[4..8].copy_from_slice(&124u32.to_le_bytes());
        b[12..16].copy_from_slice(&h.to_le_bytes());
        b[16..20].copy_from_slice(&w.to_le_bytes());
        b[28..32].copy_from_slice(&mips.to_le_bytes());
        b[76..80].copy_from_slice(&32u32.to_le_bytes());
        b[80..84].copy_from_slice(&4u32.to_le_bytes());
        b[84..88].copy_from_slice(fourcc);
        if cube {
            b[112..116].copy_from_slice(&0xfe00u32.to_le_bytes());
        }
        let block = if fourcc == b"DXT1" { 8 } else { 16 };
        let face: u32 = (0..mips).map(|m| ((w >> m).max(1).div_ceil(4) * (h >> m).max(1).div_ceil(4)) * block).sum();
        b.resize(128 + (face * if cube { 6 } else { 1 }) as usize, 0);
        b
    }

    #[test]
    fn dds_headers_and_sizes() {
        let dir = std::env::temp_dir().join(format!("texset-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("a.dds");
        std::fs::write(&p, dds(256, 128, 9, b"DXT5", false)).unwrap();
        let i = dds_info(p.to_str().unwrap()).unwrap();
        assert_eq!((i.width, i.height, i.mips, i.format.as_str(), i.block, i.cube), (256, 128, 9, "BC3", 16, false));
        // the chain as stored: 64x32 blocks of 16 bytes at level 0, down to one block
        assert_eq!(i.gpu_bytes(), (0..9).map(|m| ((256u64 >> m).max(1).div_ceil(4) * (128u64 >> m).max(1).div_ceil(4)) * 16).sum::<u64>());
        assert_eq!(i.rgba_bytes(), 256 * 128 * 4 * 4 / 3);
        let c = dir.join("c.dds");
        std::fs::write(&c, dds(64, 64, 7, b"DXT1", true)).unwrap();
        let i = dds_info(c.to_str().unwrap()).unwrap();
        assert!(i.cube && i.format == "BC1");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
