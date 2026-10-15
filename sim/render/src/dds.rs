//! The game's textures: DDS files read in place and decoded on the CPU to RGBA8 (mip 0, the first
//! layer: the first face of a cube map). The game's files use the uncompressed DX9 layouts
//! A8R8G8B8, R8G8B8, A8B8G8R8 and A1R5G5B5, and DXT1, DXT3 and DXT5 (BC1-BC3).

use std::collections::HashMap;

/// An RGBA8 image, rows top to bottom.
#[derive(Clone)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    /// the file's pixel format, for reports
    pub format: String,
}

impl Image {
    pub fn pixel(&self, x: u32, y: u32) -> [u8; 4] {
        let i = (y as usize * self.width as usize + x.min(self.width - 1) as usize) * 4;
        [self.rgba[i], self.rgba[i + 1], self.rgba[i + 2], self.rgba[i + 3]]
    }

    /// The next mip level: a 2x2 box filter (alpha-weighted colour, so transparent texels do not
    /// darken the edges).
    pub fn half(&self) -> Image {
        let (w, h) = ((self.width / 2).max(1), (self.height / 2).max(1));
        let mut out = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let mut acc = [0f32; 4];
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let p = self.pixel((2 * x + dx).min(self.width - 1), (2 * y + dy).min(self.height - 1));
                    let a = p[3] as f32;
                    for c in 0..3 {
                        acc[c] += p[c] as f32 * a;
                    }
                    acc[3] += a;
                }
                let i = ((y * w + x) * 4) as usize;
                for c in 0..3 {
                    out[i + c] = if acc[3] > 0.0 { (acc[c] / acc[3]).round() as u8 } else { 0 };
                }
                out[i + 3] = (acc[3] / 4.0).round() as u8;
            }
        }
        Image { width: w, height: h, rgba: out, format: self.format.clone() }
    }
}

/// Reads an uncompressed true-colour TGA (type 2, 24 or 32 bits: some of the game's font pages)
/// to RGBA8.
pub fn load_tga(path: &str) -> Result<Image, String> {
    let d = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    if d.len() < 18 {
        return Err(format!("{path}: not a TGA"));
    }
    let (id_len, cmap, kind) = (d[0] as usize, d[1], d[2]);
    let (w, h) = (u16::from_le_bytes([d[12], d[13]]) as u32, u16::from_le_bytes([d[14], d[15]]) as u32);
    let (bpp, desc) = (d[16] as usize, d[17]);
    if cmap != 0 || kind != 2 || (bpp != 24 && bpp != 32) {
        return Err(format!("{path}: TGA type {kind} with {bpp} bits is not read"));
    }
    let px = bpp / 8;
    let data = &d[18 + id_len..];
    if data.len() < (w * h) as usize * px {
        return Err(format!("{path}: TGA too short"));
    }
    let top_down = desc & 0x20 != 0;
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    for y in 0..h as usize {
        let src_row = if top_down { y } else { h as usize - 1 - y };
        for x in 0..w as usize {
            let s = (src_row * w as usize + x) * px;
            let o = (y * w as usize + x) * 4;
            rgba[o] = data[s + 2];
            rgba[o + 1] = data[s + 1];
            rgba[o + 2] = data[s];
            rgba[o + 3] = if px == 4 { data[s + 3] } else { 255 };
        }
    }
    Ok(Image { width: w, height: h, rgba, format: format!("TGA{bpp}") })
}

/// Reads a DDS file (or a .tga) to RGBA8.
pub fn load(path: &str) -> Result<Image, String> {
    if path.to_ascii_lowercase().ends_with(".tga") {
        return load_tga(path);
    }
    let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
    let dds = image_dds::ddsfile::Dds::read(std::io::BufReader::new(file)).map_err(|e| format!("{path}: {e}"))?;
    let format = match dds.get_d3d_format() {
        Some(f) => format!("{f:?}"),
        None => match dds.get_dxgi_format() {
            Some(f) => format!("{f:?}"),
            None => "unknown".to_string(),
        },
    };
    let surface = image_dds::SurfaceRgba8::decode_layers_mipmaps_dds(&dds, 0..1, 0..1)
        .map_err(|e| format!("{path}: {format}: {e}"))?;
    let n = (surface.width * surface.height * 4) as usize;
    let mut rgba = surface.data;
    rgba.truncate(n);
    Ok(Image { width: surface.width, height: surface.height, rgba, format })
}

/// Textures by path, loaded once; the formats seen, for reports.
#[derive(Default)]
pub struct Cache {
    pub images: HashMap<String, Result<std::sync::Arc<Image>, String>>,
}

impl Cache {
    /// The texture at `relative` (a path in the game directory, as the game's files write it).
    pub fn get(&mut self, game_dir: &str, relative: &str) -> Result<&std::sync::Arc<Image>, String> {
        let key = relative.replace('\\', "/");
        if !self.images.contains_key(&key) {
            let path = find_case_insensitive(game_dir, &key).unwrap_or_else(|| format!("{game_dir}/{key}"));
            // a texture the game names may be a .tga; only .dds is read here
            self.images.insert(key.clone(), load(&path).map(std::sync::Arc::new));
        }
        self.images[&key].as_ref().map_err(|e| e.clone())
    }

    /// The pixel formats of the textures loaded, with counts.
    pub fn formats(&self) -> Vec<(String, usize)> {
        let mut m: HashMap<String, usize> = HashMap::new();
        for r in self.images.values() {
            if let Ok(i) = r {
                *m.entry(i.format.clone()).or_default() += 1;
            }
        }
        let mut v: Vec<_> = m.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v
    }
}

/// The game's files name paths in any case (they were written for Windows): the path under
/// `root` whose components match `relative`'s ignoring case.
pub fn find_case_insensitive(root: &str, relative: &str) -> Option<String> {
    let direct = format!("{root}/{relative}");
    if std::path::Path::new(&direct).exists() {
        return Some(direct);
    }
    let mut dir = std::path::PathBuf::from(root);
    for part in relative.split('/').filter(|p| !p.is_empty()) {
        let exact = dir.join(part);
        if exact.exists() {
            dir = exact;
            continue;
        }
        let lower = part.to_lowercase();
        let found = std::fs::read_dir(&dir).ok()?.flatten().find(|e| e.file_name().to_string_lossy().to_lowercase() == lower)?;
        dir = found.path();
    }
    Some(dir.to_string_lossy().into_owned())
}

/// A cube map's six faces (+x, -x, +y, -y, +z, -z: the DDS's order and wgpu's), decoded and
/// stacked top to bottom: an image `size` wide and 6 x `size` high, format "cube <format>"; the
/// file's further mip levels follow in `rgba`, each as six faces (the pre-filtered environment
/// maps are sampled by level).
pub fn load_cube(path: &str, max_levels: u32) -> Result<Image, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
    let dds = image_dds::ddsfile::Dds::read(std::io::BufReader::new(file)).map_err(|e| format!("{path}: {e}"))?;
    let format = match dds.get_d3d_format() {
        Some(f) => format!("{f:?}"),
        None => dds.get_dxgi_format().map_or("unknown".to_string(), |f| format!("{f:?}")),
    };
    let mips = dds.get_num_mipmap_levels().clamp(1, max_levels.max(1));
    let surface = image_dds::SurfaceRgba8::decode_layers_mipmaps_dds(&dds, 0..6, 0..mips).map_err(|e| format!("{path}: {format}: {e}"))?;
    if surface.layers < 6 {
        return Err(format!("{path}: not a cube map ({} layers)", surface.layers));
    }
    let mut rgba = Vec::new();
    for m in 0..surface.mipmaps {
        if (surface.width >> m).max(1) < 4 {
            break;
        }
        for f in 0..6 {
            rgba.extend_from_slice(surface.get(f, 0, m).ok_or_else(|| format!("{path}: face {f} level {m} missing"))?);
        }
    }
    Ok(Image { width: surface.width, height: surface.height * 6, rgba, format: format!("cube {format}") })
}

/// The mip levels a cube map image of load_cube holds.
pub fn cube_levels(img: &Image) -> u32 {
    let mut left = img.rgba.len();
    let mut n = 0;
    let mut s = img.width as usize;
    while s >= 1 && left >= s * s * 24 {
        left -= s * s * 24;
        n += 1;
        s /= 2;
    }
    n.max(1)
}

impl Cache {
    /// A cube map at `relative` (see load_cube) with at most `levels` mip levels, loaded once.
    pub fn get_cube(&mut self, game_dir: &str, relative: &str, levels: u32) -> Result<&std::sync::Arc<Image>, String> {
        let rel = relative.replace('\\', "/");
        let key = format!("cube{levels}:{rel}");
        if !self.images.contains_key(&key) {
            let path = find_case_insensitive(game_dir, &rel).unwrap_or_else(|| format!("{game_dir}/{rel}"));
            self.images.insert(key.clone(), load_cube(&path, levels).map(std::sync::Arc::new));
        }
        self.images[&key].as_ref().map_err(|e| e.clone())
    }
}
