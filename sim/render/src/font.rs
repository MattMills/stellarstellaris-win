//! The game's bitmap fonts: an AngelCode BMFont text file (`gfx/fonts/cg_16b.fnt`: `common
//! lineHeight base scaleW scaleH`, one `char id x y width height xoffset yoffset xadvance` per
//! glyph, `kerning first second amount`) and its page texture (`cg_16b.dds`, the same name).

use std::collections::HashMap;

use crate::dds::{self, Image};

#[derive(Clone, Copy, Debug)]
pub struct Glyph {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub xoffset: f32,
    pub yoffset: f32,
    pub xadvance: f32,
}

pub struct Font {
    pub name: String,
    pub line_height: f32,
    pub base: f32,
    /// `info padding=up,right,down,left`: the glyph cells' padding (pixels)
    pub padding: [f32; 4],
    pub glyphs: HashMap<char, Glyph>,
    pub kerning: HashMap<(char, char), f32>,
    /// the page texture's path in the game directory, and its image
    pub texture: String,
    pub image: Image,
}

fn attrs(line: &str) -> HashMap<&str, &str> {
    line.split_whitespace().filter_map(|kv| kv.split_once('=')).map(|(k, v)| (k, v.trim_matches('"'))).collect()
}

impl Font {
    /// Reads `<file>.fnt` and its page (`<file>.dds`, or the `page file=` it names) under
    /// `game_dir`; `file` as a .gfx `fontfiles` entry writes it ("gfx/fonts/cg_16b").
    pub fn load(game_dir: &str, name: &str, file: &str) -> Result<Font, String> {
        let fnt_rel = format!("{file}.fnt");
        let fnt = dds::find_case_insensitive(game_dir, &fnt_rel).ok_or(format!("{fnt_rel}: not found"))?;
        let text = std::fs::read_to_string(&fnt).map_err(|e| format!("{fnt}: {e}"))?;
        let mut font = Font {
            name: name.to_string(),
            line_height: 16.0,
            base: 13.0,
            padding: [0.0; 4],
            glyphs: HashMap::new(),
            kerning: HashMap::new(),
            texture: String::new(),
            image: Image { width: 1, height: 1, rgba: vec![0; 4], format: String::new() },
        };
        let mut page = None;
        for line in text.lines() {
            let tag = line.split_whitespace().next().unwrap_or("");
            let a = attrs(line);
            let num = |k: &str| a.get(k).and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0);
            match tag {
                "info" => {
                    if let Some(p) = a.get("padding") {
                        for (k, v) in p.split(',').take(4).enumerate() {
                            font.padding[k] = v.trim().parse().unwrap_or(0.0);
                        }
                    }
                }
                "common" => {
                    font.line_height = num("lineHeight");
                    font.base = num("base");
                }
                "page" => page = a.get("file").map(|s| s.to_string()),
                "char" => {
                    if let Some(c) = a.get("id").and_then(|v| v.parse::<u32>().ok()).and_then(char::from_u32) {
                        font.glyphs.insert(
                            c,
                            Glyph {
                                x: num("x"),
                                y: num("y"),
                                width: num("width"),
                                height: num("height"),
                                xoffset: num("xoffset"),
                                yoffset: num("yoffset"),
                                xadvance: num("xadvance"),
                            },
                        );
                    }
                }
                "kerning" => {
                    let c = |k: &str| a.get(k).and_then(|v| v.parse::<u32>().ok()).and_then(char::from_u32);
                    if let (Some(f), Some(s)) = (c("first"), c("second")) {
                        font.kerning.insert((f, s), num("amount"));
                    }
                }
                _ => {}
            }
        }
        // the page: the .dds beside the .fnt (the game's files name the page .tga or .png, and
        // ship the texture as .dds)
        let dir = file.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
        let stem = page.as_deref().and_then(|p| p.rsplit_once('.').map(|(s, _)| s.to_string()));
        let mut tried = Vec::new();
        let candidates = [
            Some(format!("{file}.dds")),
            stem.map(|s| format!("{dir}/{s}.dds")),
            Some(format!("{file}.tga")),
            page.as_ref().map(|p| format!("{dir}/{p}")),
        ];
        for candidate in candidates.into_iter().flatten() {
            if let Some(path) = dds::find_case_insensitive(game_dir, &candidate) {
                if std::path::Path::new(&path).exists() {
                    font.image = dds::load(&path)?;
                    font.texture = candidate;
                    return Ok(font);
                }
            }
            tried.push(candidate);
        }
        Err(format!("{name}: no page texture ({})", tried.join(", ")))
    }

    /// The width of `text` in pixels (the sum of the advances, with kerning).
    pub fn width(&self, text: &str) -> f32 {
        let mut w = 0.0;
        let mut prev = None;
        for c in text.chars() {
            if let Some(g) = self.glyphs.get(&c) {
                w += g.xadvance + prev.and_then(|p| self.kerning.get(&(p, c))).copied().unwrap_or(0.0);
            }
            prev = Some(c);
        }
        w
    }

    /// The glyphs of `text` with the pen starting at (x, y), y the top of the line: each glyph's
    /// character, its rectangle on screen and its rectangle in the page (pixels).
    pub fn place(&self, text: &str, x: f32, y: f32) -> Vec<(char, [f32; 4], [f32; 4])> {
        let mut out = Vec::new();
        let mut pen = x;
        let mut prev = None;
        for c in text.chars() {
            let Some(g) = self.glyphs.get(&c) else { continue };
            pen += prev.and_then(|p| self.kerning.get(&(p, c))).copied().unwrap_or(0.0);
            let (x0, y0) = (pen + g.xoffset, y + g.yoffset);
            out.push((c, [x0, y0, x0 + g.width, y0 + g.height], [g.x, g.y, g.x + g.width, g.y + g.height]));
            pen += g.xadvance;
            prev = Some(c);
        }
        out
    }
}
