//! The game's mesh effects (gfx/FX/pdxmesh.shader `Effect NAME { VertexShader PixelShader
//! BlendState RasterizerState DepthStencilState Defines = { ... } }`), read once: a part's shader
//! name to the defines its pixel shader is compiled with, which mesh.wgsl's PixelPdxMeshStandard
//! port switches on.

use std::collections::HashMap;
use std::sync::OnceLock;

/// The defines mesh.wgsl knows, as bits of the draw's flags.
pub const IS_PLANET: u32 = 1;
pub const EMISSIVE: u32 = 2;
pub const NO_PLANET_EMISSIVE: u32 = 4;
pub const USE_FLOWMAP: u32 = 8;
pub const EMISSIVE_FLOW: u32 = 16;
pub const IS_CLOUDS: u32 = 32;
pub const IS_RING: u32 = 64;
pub const PLANET_LIGHTS_EMISSIVE: u32 = 128;
pub const NO_ALPHA_MULTIPLIED_EMISSIVE: u32 = 256;
pub const ADD_COLOR: u32 = 512;
pub const ANIMATE_UV: u32 = 1024;
pub const USE_NORMALMAP_AS_ALPHA: u32 = 2048;
pub const BLACK_HOLE: u32 = 4096;
pub const USE_EMPIRE_COLOR: u32 = 8192;
pub const ANIMATE_UV_ALPHA: u32 = 16384;
pub const RIM_LIGHT: u32 = 32768;
pub const GLOSSY_EMISSIVE: u32 = 65536;
pub const USE_EMPIRE_COLOR_MASK_FOR_EMISSIVE: u32 = 131072;
/// not a define: the effect's pixel shader is PixelPdxMeshShip
pub const SHIP: u32 = 262144;

#[derive(Clone, Debug, Default)]
pub struct Effect {
    pub pixel_shader: String,
    pub blend: String,
    pub raster: String,
    pub depth: String,
    pub defines: Vec<String>,
}

impl Effect {
    pub fn flags(&self) -> u32 {
        let mut f = 0;
        for d in &self.defines {
            f |= match d.as_str() {
                "IS_PLANET" => IS_PLANET,
                "EMISSIVE" => EMISSIVE,
                "NO_PLANET_EMISSIVE" => NO_PLANET_EMISSIVE,
                "USE_FLOWMAP" => USE_FLOWMAP,
                "EMISSIVE_FLOW" => EMISSIVE_FLOW,
                "IS_CLOUDS" => IS_CLOUDS,
                "IS_RING" => IS_RING,
                "PLANET_LIGHTS_EMISSIVE" => PLANET_LIGHTS_EMISSIVE,
                "NO_ALPHA_MULTIPLIED_EMISSIVE" => NO_ALPHA_MULTIPLIED_EMISSIVE,
                "ADD_COLOR" => ADD_COLOR,
                "ANIMATE_UV" => ANIMATE_UV,
                "USE_NORMALMAP_AS_ALPHA" => USE_NORMALMAP_AS_ALPHA,
                "BLACK_HOLE" => BLACK_HOLE,
                "USE_EMPIRE_COLOR" => USE_EMPIRE_COLOR,
                "ANIMATE_UV_ALPHA" => ANIMATE_UV_ALPHA,
                "RIM_LIGHT" => RIM_LIGHT,
                "GLOSSY_EMISSIVE" => GLOSSY_EMISSIVE,
                "USE_EMPIRE_COLOR_MASK_FOR_EMISSIVE" => USE_EMPIRE_COLOR_MASK_FOR_EMISSIVE,
                _ => 0,
            };
        }
        if self.pixel_shader == "PixelPdxMeshShip" {
            f |= SHIP;
        }
        f
    }
}

static EFFECTS: OnceLock<HashMap<String, Effect>> = OnceLock::new();

/// The effects of gfx/FX/pdxmesh.shader by lower-case name (read on first use).
pub fn all(game_dir: &str) -> &'static HashMap<String, Effect> {
    EFFECTS.get_or_init(|| {
        let path = crate::dds::find_case_insensitive(game_dir, "gfx/FX/pdxmesh.shader").unwrap_or_default();
        parse(&std::fs::read_to_string(path).unwrap_or_default())
    })
}

/// An effect by name (any case).
pub fn effect(game_dir: &str, name: &str) -> Option<&'static Effect> {
    all(game_dir).get(&name.to_ascii_lowercase())
}

fn quoted(s: &str) -> Vec<String> {
    s.split('"').skip(1).step_by(2).map(|x| x.to_string()).collect()
}

/// `Effect NAME { key = "value" ... Defines = { "A" "B" } }` blocks; `#` comments dropped. A
/// repeated `Defines` adds to the list (PdxMeshPlanetRingsSkinned has two).
pub fn parse(text: &str) -> HashMap<String, Effect> {
    let mut out = HashMap::new();
    let lines: Vec<&str> = text.lines().map(|l| l.split('#').next().unwrap_or("")).collect();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i].trim();
        if let Some(name) = l.strip_prefix("Effect ") {
            let name = name.trim().trim_end_matches('{').trim().to_string();
            let mut e = Effect::default();
            let mut depth = 0i32;
            let mut started = false;
            while i < lines.len() {
                let l = lines[i];
                for c in l.chars() {
                    if c == '{' {
                        depth += 1;
                        started = true;
                    } else if c == '}' {
                        depth -= 1;
                    }
                }
                let t = l.trim();
                let value = |key: &str| -> Option<String> {
                    let rest = t.strip_prefix(key)?.trim_start();
                    let rest = rest.strip_prefix('=')?;
                    quoted(rest).into_iter().next()
                };
                if let Some(v) = value("PixelShader") {
                    e.pixel_shader = v;
                } else if let Some(v) = value("BlendState") {
                    e.blend = v;
                } else if let Some(v) = value("RasterizerState") {
                    e.raster = v;
                } else if let Some(v) = value("DepthStencilState") {
                    e.depth = v;
                } else if t.starts_with("Defines") {
                    e.defines.extend(quoted(t));
                }
                i += 1;
                if started && depth <= 0 {
                    break;
                }
            }
            out.insert(name.to_ascii_lowercase(), e);
            continue;
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_an_effect() {
        let e = super::parse(
            "Effect PdxMeshPlanetRings\n{\n\tVertexShader = \"VertexPdxMeshStandard\"\n\tPixelShader = \"PixelPdxMeshStandard\"\n\tRasterizerState = \"RasterizerStateNoCulling\"\n\tBlendState = \"BlendStateAlphaBlendWriteAlpha\" # x\n\tDefines = { \"IS_PLANET\" \"IS_RING\" }\n}\n",
        );
        let r = &e["pdxmeshplanetrings"];
        assert_eq!(r.pixel_shader, "PixelPdxMeshStandard");
        assert_eq!(r.blend, "BlendStateAlphaBlendWriteAlpha");
        assert_eq!(r.flags(), super::IS_PLANET | super::IS_RING);
    }
}
