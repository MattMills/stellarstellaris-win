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

/// A texture kept as its file has it, block-compressed (BC1, BC2, BC3, BC7: 4x4 blocks), its mip
/// levels the file's: uploaded to the GPU as they are, never decoded on the CPU
/// (docs/profiling.md section 13). Each level: its size and its blocks.
pub struct Compressed {
    pub format: wgpu::TextureFormat,
    pub block_bytes: u32,
    /// the file (its levels read again from it if they are wanted after an upload freed them)
    pub path: String,
    pub levels: Vec<(u32, u32, Vec<u8>)>,
    /// a cube map (its levels' six faces one after the other), its levels at most this
    pub cube: Option<u32>,
}

impl Compressed {
    pub fn bytes(&self) -> usize {
        self.levels.iter().map(|l| l.2.len()).sum()
    }

    /// Its levels: those kept, or read from the file again (after an upload freed them).
    pub fn levels(&self) -> Option<std::borrow::Cow<'_, [(u32, u32, Vec<u8>)]>> {
        if !self.levels.is_empty() {
            return Some(std::borrow::Cow::Borrowed(&self.levels));
        }
        let info = crate::texset::dds_info(&self.path)?;
        match self.cube {
            Some(max) => read_cube_levels(&self.path, &info, max),
            None => read_levels(&self.path, &info),
        }
        .map(std::borrow::Cow::Owned)
    }
}

/// Whether the GPU takes block-compressed textures (the device was made with
/// TEXTURE_COMPRESSION_BC: render.rs); set once the device is made.
static BC: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn set_bc(on: bool) {
    BC.store(on, std::sync::atomic::Ordering::Relaxed);
}

pub fn bc() -> bool {
    BC.load(std::sync::atomic::Ordering::Relaxed)
}

/// The compressed levels of the placeholder images ([`load_compressed`]), by the image's address:
/// the renderer uploads them; taken (freed here) once it has.
static COMPRESSED: std::sync::Mutex<Option<HashMap<usize, (std::sync::Weak<Image>, std::sync::Arc<Compressed>)>>> = std::sync::Mutex::new(None);

/// The compressed levels of `img` if it is a placeholder of [`load_compressed`] (its pixels on the
/// GPU, none here).
pub fn compressed_of(img: &std::sync::Arc<Image>) -> Option<std::sync::Arc<Compressed>> {
    let key = std::sync::Arc::as_ptr(img) as usize;
    let g = COMPRESSED.lock().unwrap();
    let (w, c) = g.as_ref()?.get(&key)?;
    w.upgrade().filter(|i| std::sync::Arc::ptr_eq(i, img)).map(|_| c.clone())
}

/// The compressed levels of `img` uploaded: their bytes freed here (the GPU has them; read from the
/// file again if it is uploaded again).
pub fn uploaded(img: &std::sync::Arc<Image>) {
    if let Some(m) = COMPRESSED.lock().unwrap().as_mut() {
        if let Some((_, c)) = m.get_mut(&(std::sync::Arc::as_ptr(img) as usize)) {
            *c = std::sync::Arc::new(Compressed { format: c.format, block_bytes: c.block_bytes, path: c.path.clone(), levels: Vec::new(), cube: c.cube });
        }
    }
}

/// Whether a texture at `relative` may be kept compressed: a model's (gfx/models: ships, stations,
/// planets, stars, portraits), which only the GPU reads; the GUI's and the composed images'
/// sources are decoded (their pixels read on the CPU).
pub fn compressible(relative: &str) -> bool {
    bc() && relative.to_ascii_lowercase().starts_with("gfx/models/")
}

/// A texture read compressed as its file has it: a placeholder image (its size, no pixels: the
/// format `BCn on the GPU`) whose levels the renderer uploads. None if the file is not BC1, BC2,
/// BC3 or BC7, not a plain 2D texture, or its size is not a multiple of 4 (then decoded).
pub fn load_compressed(path: &str) -> Option<std::sync::Arc<Image>> {
    let info = crate::texset::dds_info(path)?;
    let format = match info.format.as_str() {
        "BC1" => wgpu::TextureFormat::Bc1RgbaUnorm,
        "BC2" => wgpu::TextureFormat::Bc2RgbaUnorm,
        "BC3" => wgpu::TextureFormat::Bc3RgbaUnorm,
        "BC7" => wgpu::TextureFormat::Bc7RgbaUnorm,
        _ => return None,
    };
    if info.cube || info.width % 4 != 0 || info.height % 4 != 0 || info.width == 0 || info.height == 0 {
        return None;
    }
    let levels = read_levels(path, &info)?;
    let img = std::sync::Arc::new(Image { width: info.width, height: info.height, rgba: Vec::new(), format: format!("{} on the GPU", info.format) });
    let c = std::sync::Arc::new(Compressed { format, block_bytes: info.block, path: path.to_string(), levels, cube: None });
    let mut g = COMPRESSED.lock().unwrap();
    let m = g.get_or_insert_with(HashMap::new);
    if m.len() > 256 {
        m.retain(|_, (w, _)| w.strong_count() > 0);
    }
    m.insert(std::sync::Arc::as_ptr(&img) as usize, (std::sync::Arc::downgrade(&img), c));
    Some(img)
}

/// A compressed file's levels: each one's size and blocks, as many as the file holds.
fn read_levels(path: &str, info: &crate::texset::DdsInfo) -> Option<Vec<(u32, u32, Vec<u8>)>> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() < 128 {
        return None;
    }
    // the header (128 bytes, and the DX10 one's 20 when it has one)
    let dx10 = &bytes[84..88] == b"DX10";
    let mut at = if dx10 { 148 } else { 128 };
    let mut levels = Vec::new();
    for m in 0..info.mips {
        let (w, h) = ((info.width >> m).max(1), (info.height >> m).max(1));
        let n = (w.div_ceil(4) * h.div_ceil(4) * info.block) as usize;
        if at + n > bytes.len() {
            break;
        }
        levels.push((w, h, bytes[at..at + n].to_vec()));
        at += n;
    }
    (!levels.is_empty()).then_some(levels)
}

/// A cube map's levels read compressed (BC1-BC3, BC7, its size a multiple of 4): each level's six
/// faces' blocks one after the other (the order of a 6-layer texture), at most `max_levels`, none
/// under 4 pixels (as load_cube). The file holds each face with its whole mip chain in turn.
fn read_cube_levels(path: &str, info: &crate::texset::DdsInfo, max_levels: u32) -> Option<Vec<(u32, u32, Vec<u8>)>> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() < 128 {
        return None;
    }
    let dx10 = &bytes[84..88] == b"DX10";
    let start = if dx10 { 148 } else { 128 };
    let level_bytes = |m: u32| -> usize {
        let (w, h) = ((info.width >> m).max(1), (info.height >> m).max(1));
        (w.div_ceil(4) * h.div_ceil(4) * info.block) as usize
    };
    let face: usize = (0..info.mips).map(level_bytes).sum();
    if start + face * 6 > bytes.len() {
        return None;
    }
    let mut levels = Vec::new();
    let mut offset = 0usize;
    for m in 0..info.mips.min(max_levels.max(1)) {
        let (w, h) = ((info.width >> m).max(1), (info.height >> m).max(1));
        if w < 4 {
            break;
        }
        let n = level_bytes(m);
        let mut all = Vec::with_capacity(n * 6);
        for f in 0..6 {
            let at = start + f * face + offset;
            all.extend_from_slice(&bytes[at..at + n]);
        }
        levels.push((w, h, all));
        offset += n;
    }
    (!levels.is_empty()).then_some(levels)
}

/// A cube map read compressed as its file has it (see [`load_compressed`]): a placeholder image in
/// load_cube's shape (its size, six faces stacked, no pixels) whose levels the renderer uploads.
pub fn load_cube_compressed(path: &str, max_levels: u32) -> Option<std::sync::Arc<Image>> {
    let info = crate::texset::dds_info(path)?;
    let format = match info.format.as_str() {
        "BC1" => wgpu::TextureFormat::Bc1RgbaUnorm,
        "BC2" => wgpu::TextureFormat::Bc2RgbaUnorm,
        "BC3" => wgpu::TextureFormat::Bc3RgbaUnorm,
        "BC7" => wgpu::TextureFormat::Bc7RgbaUnorm,
        _ => return None,
    };
    if !info.cube || info.width != info.height || info.width % 4 != 0 || info.width == 0 {
        return None;
    }
    let levels = read_cube_levels(path, &info, max_levels)?;
    let img = std::sync::Arc::new(Image { width: info.width, height: info.height * 6, rgba: Vec::new(), format: format!("cube {} on the GPU", info.format) });
    let c = std::sync::Arc::new(Compressed { format, block_bytes: info.block, path: path.to_string(), levels, cube: Some(max_levels) });
    let mut g = COMPRESSED.lock().unwrap();
    let m = g.get_or_insert_with(HashMap::new);
    m.insert(std::sync::Arc::as_ptr(&img) as usize, (std::sync::Arc::downgrade(&img), c));
    Some(img)
}

/// A cube map at `path` as dds::Cache keeps it: compressed for the GPU when it can be, else
/// decoded (load_cube).
pub fn load_cube_texture(path: &str, levels: u32) -> Result<std::sync::Arc<Image>, String> {
    if bc() {
        if let Some(img) = load_cube_compressed(path, levels) {
            return Ok(img);
        }
    }
    load_cube(path, levels).map(std::sync::Arc::new)
}

/// A texture at `relative` (found at `path`) as dds::Cache keeps it: compressed for the GPU when it
/// may be ([`compressible`], [`load_compressed`]), else decoded.
pub fn load_texture(relative: &str, path: &str) -> Result<std::sync::Arc<Image>, String> {
    if compressible(relative) {
        if let Some(img) = load_compressed(path) {
            return Ok(img);
        }
    }
    load(path).map(std::sync::Arc::new)
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
            // a .tga the game names where only the .dds is shipped: the .dds (settings_view.gfx's
            // scrollbar_leftbutton.tga, drawn by the game's galaxy settings) [I]
            let dds = key.strip_suffix(".tga").map(|b| format!("{b}.dds"));
            let path = find_case_insensitive(game_dir, &key)
                .or_else(|| dds.as_ref().and_then(|d| find_case_insensitive(game_dir, d)))
                .unwrap_or_else(|| format!("{game_dir}/{key}"));
            // (prepared ahead on a worker: prepare.rs; else decoded here, and noted for the window built)
            let r = match crate::prepare::take(&key) {
                Some(r) => r,
                None => {
                    let _s = crate::prof::span("texture: dds read, decode");
                    crate::prepare::record(&key);
                    load_texture(&key, &path)
                }
            };
            self.images.insert(key.clone(), r);
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
            let r = match crate::prepare::take(&key) {
                Some(r) => r,
                None => {
                    let _s = crate::prof::span("texture: cube map read, decode");
                    crate::prepare::record(&key);
                    load_cube_texture(&path, levels)
                }
            };
            self.images.insert(key.clone(), r);
        }
        self.images[&key].as_ref().map_err(|e| e.clone())
    }
}
