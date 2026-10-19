//! Tooltips (docs/tooltips.md): what the cursor rests on (App::hovered: a GUI element or a thing
//! on the map), its text, and core.gui's `ToolTipWindow` drawn by the cursor, as the 4.5.2 game
//! does it (CTooltipManager, CTooltipWindow: the Linux build's rules, addresses in the doc).
//!
//! The text, first found: the `Tooltips` hook (App::tooltips); the texts render.tooltip builds
//! from the world (the top bar's resources, the outliner's rows, the map's stars, planets and
//! fleets); the element's own (a window's `tooltips` table, else the .gui's pdx_tooltip, carried
//! on its GuiItem). The text is localised and its colour codes and icons drawn as any GUI text.

use std::time::Duration;

use crate::app::{App, HoverTarget};
use crate::gui::{self, GuiItem};
use crate::scene::Pickable;

/// NInterface::TOOLTIP_TIME: the rest before a tooltip shows (unchecked_defines/00_interface.txt)
pub const DELAY: Duration = Duration::from_millis(50);
/// NInterface::TOOLTIP_POSITION_OFFSET: the window's corner from the cursor
const OFFSET: (f32, f32) = (21.0, 24.0);
/// ToolTipWindow's text: borderSize 35 x 15 on each side, maxWidth 500 (lines wrap at 430)
const BORDER: (f32, f32) = (35.0, 15.0);
const MAX_WIDTH: f32 = 500.0;
const MAX_LINES: usize = 70;

/// The tooltip shown (for App: what was drawn, so a new rest or target draws it again).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tip {
    /// the target and cursor the scene was built with a tooltip for
    pub drawn: Option<(HoverTarget, (i32, i32))>,
}

/// Whether the scene must be built again: the cursor has rested long enough on a target with a
/// tooltip not drawn yet, or the one drawn is no longer the target.
pub fn due(app: &App) -> bool {
    let want = wanted(app);
    want != app.tip.drawn
}

/// The target and cursor a tooltip is wanted for now.
fn wanted(app: &App) -> Option<(HoverTarget, (i32, i32))> {
    let (target, since) = app.hovered.clone()?;
    if since.elapsed() < DELAY {
        return None;
    }
    let (x, y) = app.cursor?;
    Some((target, (x as i32, y as i32)))
}

/// The GUI element under the cursor that has a tooltip but takes no clicks (an icon, a group's
/// background): the top bar's, then the windows' from the top. Its path.
pub fn element_at(app: &mut App, x: f32, y: f32) -> Option<String> {
    let (w, h) = app.size;
    let mut hit = None;
    let topbar = app.map.as_mut().and_then(|m| m.topbar(w, h).ok());
    let lists: [&[GuiItem]; 2] = [topbar.as_ref().map_or(&[][..], |t| &t.items[..]), &app.overlay_items[..]];
    for items in lists {
        for it in items.iter() {
            if let GuiItem::Sprite { path, x: ix, y: iy, w: iw, h: ih, tooltip: Some(_), .. } = it {
                if x >= *ix && x < ix + iw && y >= *iy && y < iy + ih {
                    hit = Some(path.clone());
                }
            }
        }
    }
    hit
}

/// The raw tooltip (a text or a key) a GUI element carries.
fn item_tooltip(app: &mut App, path: &str) -> Option<String> {
    let (w, h) = app.size;
    let find = |items: &[GuiItem]| {
        items.iter().rev().find_map(|it| match it {
            GuiItem::Sprite { path: p, tooltip, .. } if p == path => tooltip.clone(),
            _ => None,
        })
    };
    if let Some(t) = find(&app.overlay_items) {
        return Some(t);
    }
    let topbar = app.map.as_mut().and_then(|m| m.topbar(w, h).ok())?;
    find(&topbar.items)
}

/// The text of a target (raw: localised by the layout), if it has one.
fn text(app: &mut App, target: &HoverTarget) -> Option<String> {
    let date = app.map.as_ref().map(|m| m.date()).unwrap_or_default();
    if let Some(hook) = app.tooltips.as_mut() {
        if let Some(t) = hook.text(target, &date) {
            return Some(t);
        }
    }
    // the clock's state for the time window's texts
    let paused = app.map.as_ref().is_some_and(|m| m.paused);
    let _ = app.runtime.lua.globals().set("RENDER_TOOLTIP_PAUSED", paused);
    let _ = app.runtime.lua.globals().set("RENDER_TOOLTIP_SPEED", app.map.as_ref().map_or(3, |m| m.speed));
    // a body of the system shown: its name and class (the system's data)
    if let (HoverTarget::Map(Pickable::Body(id)), crate::app::MapView::System(i)) = (target, app.view) {
        let body = app.map.as_mut().and_then(|m| {
            let sid = m.galaxy.systems.get(i)?.id;
            let d = m.system_data(sid).ok()?;
            d.bodies.iter().find(|b| b.id == *id).map(|b| (b.name.clone(), b.class.clone()))
        });
        if let Some((name, class)) = body {
            let lua = &app.runtime.lua;
            let t: Option<String> = name
                .to_lua(lua)
                .and_then(|n| lua.load("local n, c = ... return require('render.tooltip').planet(n, c)").call((n, class)))
                .ok();
            return t;
        }
    }
    let lua = &app.runtime.lua;
    let built: Option<String> = match target {
        HoverTarget::Element(path) => lua
            .load("local p = ... return require('render.tooltip').element(p)")
            .call::<Option<String>>(path.as_str())
            .unwrap_or_else(|e| {
                eprintln!("tooltip: {e}");
                None
            }),
        HoverTarget::Map(p) => {
            let (kind, id) = match p {
                Pickable::System(i) => ("system", app.map.as_ref().and_then(|m| m.galaxy.systems.get(*i)).map_or(0, |s| s.id)),
                Pickable::Body(id) => ("planet", *id),
                Pickable::Fleet(id) => ("fleet", *id),
                Pickable::Ship(id) => ("ship", *id),
            };
            lua.load("local k, i = ... return require('render.tooltip').map(k, i)").call::<Option<String>>((kind, id)).unwrap_or_else(|e| {
                eprintln!("tooltip: {e}");
                None
            })
        }
    };
    if built.is_some() {
        return built;
    }
    let raw = match target {
        HoverTarget::Element(path) => item_tooltip(app, path)?,
        _ => return None,
    };
    // localised, with its shortcut's line (render.tooltip.resolve)
    let text: Option<String> = app.runtime.lua.load("local r = ... return require('render.tooltip').resolve(r)").call(raw).ok();
    text.filter(|t| !t.is_empty())
}

/// The tooltip's items, if one is due: core.gui's ToolTipWindow (GFX_tooltip_bg, a cornered tile
/// sized to the text + its borders) at the cursor + (21, 24), kept on the screen (CTooltipWindow:
/// clamped at the right, above the cursor at the bottom); its text in lines (cg_16b, 430 wide).
pub fn items(app: &mut App) -> Vec<GuiItem> {
    let want = wanted(app);
    app.tip.drawn = want.clone();
    let Some((target, (cx, cy))) = want else { return Vec::new() };
    let Some(raw) = text(app, &target) else { return Vec::new() };
    let side = matches!(&target, HoverTarget::Element(p) if p.starts_with("/outliner/"));
    match layout(app, &raw, cx as f32, cy as f32, side) {
        Ok(items) => items,
        Err(e) => {
            app.log.push(format!("tooltip: {e}"));
            Vec::new()
        }
    }
}

fn layout(app: &mut App, raw: &str, cx: f32, cy: f32, side: bool) -> Result<Vec<GuiItem>, String> {
    let (w, h) = app.size;
    // the text's spans (render.gui: localised, coloured, its icons) through the window's own text
    let mut spec = gui::WindowSpec::new("interface/core.gui", "ToolTipWindow");
    spec.hide.push("locked_indicator_window".into());
    spec.text.push(("/ToolTipWindow/text".into(), raw.to_string()));
    let laid = gui::layout_specs(&app.runtime, w, h, &spec_list(spec))?;
    let mut bg = None;
    let mut spans = Vec::new();
    let mut font = "cg_16b".to_string();
    for it in laid.items {
        match it {
            GuiItem::Sprite { ref path, .. } if path == "/ToolTipWindow/background" => bg = Some(it),
            GuiItem::Text { spans: s, font: f, .. } => {
                spans = s;
                font = f;
            }
            _ => {}
        }
    }
    let Some(mut bg) = bg else { return Ok(Vec::new()) };
    // the font's metrics (loaded with the windows' fonts)
    let probe = vec![GuiItem::Text { path: String::new(), font: font.clone(), text: String::new(), spans: Vec::new(), x: 0.0, y: 0.0, w: 0.0, h: 0.0, format: String::new(), valign: String::new(), fixed: true }];
    let map = app.map.as_mut().ok_or("no map")?;
    gui::fonts(&app.runtime, &app.game_dir, &probe, map.fonts.get_or_insert_with(Default::default))?;
    let f = map.fonts.as_ref().and_then(|m| m.get(&font)).ok_or("no font")?;
    let lh = f.line_height.max(1.0);
    let measure = |s: &str| if s.starts_with('\u{1}') { lh } else { f.width(s) };
    let lines = wrap(&spans, MAX_WIDTH - 2.0 * BORDER.0, &measure);
    let lines: Vec<_> = lines.into_iter().take(MAX_LINES).collect();
    let text_w = lines.iter().map(|l| l.iter().map(|(s, _)| measure(s)).sum::<f32>()).fold(0.0, f32::max);
    let (bw, bh) = (text_w.ceil() + 2.0 * BORDER.0, lines.len() as f32 * lh + 2.0 * BORDER.1);
    // the place: the cursor + the offset; at the right edge moved left, at the bottom above the
    // cursor; never off the top or the left
    let mut x = cx + OFFSET.0;
    let mut y = cy + OFFSET.1;
    if x + bw > w as f32 {
        x = w as f32 - bw;
    }
    if y + bh > h as f32 {
        y = cy - OFFSET.1 - bh;
    }
    // an outliner row's (COutlinerMember::GetToolTip @0x2fed720: outliner_tooltip_offset (-130,
    // -30) added to the offset, its flag +0xc9 set): right-aligned at the cursor + (21 - 130),
    // its top at the cursor + (24 - 30) [V for the offset; I: the flag right-aligns, by the game's
    // frame of 2210.01.01]
    if side {
        x = cx + OFFSET.0 - 130.0 - bw;
        y = cy + OFFSET.1 - 30.0;
        if y + bh > h as f32 {
            y = h as f32 - bh;
        }
    }
    let (x, y) = (x.max(0.0), y.max(0.0));
    if let GuiItem::Sprite { x: ix, y: iy, w: iw, h: ih, .. } = &mut bg {
        *ix = x;
        *iy = y;
        *iw = bw;
        *ih = bh;
    }
    let mut out = vec![bg];
    for (i, line) in lines.into_iter().enumerate() {
        let lw: f32 = line.iter().map(|(s, _)| measure(s)).sum();
        out.push(GuiItem::Text {
            path: format!("/tooltip/line/{i}"),
            font: font.clone(),
            text: line.iter().map(|(s, _)| s.as_str()).collect(),
            spans: line,
            x: x + BORDER.0,
            y: y + BORDER.1 + i as f32 * lh,
            w: lw + 4.0,
            h: lh,
            format: "left".into(),
            valign: "top".into(),
            fixed: true,
        });
    }
    Ok(out)
}

fn spec_list(s: gui::WindowSpec) -> Vec<gui::WindowSpec> {
    vec![s]
}

/// Spans broken into lines no wider than `w`: at their line breaks and at spaces; an icon span
/// ("\u{1}texture...") is a word of its own.
fn wrap(spans: &[(String, [f32; 3])], w: f32, measure: &dyn Fn(&str) -> f32) -> Vec<Vec<(String, [f32; 3])>> {
    let mut lines: Vec<Vec<(String, [f32; 3])>> = vec![Vec::new()];
    let mut used = 0.0;
    for (s, c) in spans {
        if s.starts_with('\u{1}') {
            let ww = measure(s);
            if used > 0.0 && used + ww > w + 0.5 {
                lines.push(Vec::new());
                used = 0.0;
            }
            lines.last_mut().unwrap().push((s.clone(), *c));
            used += ww;
            continue;
        }
        for (i, para) in s.split('\n').enumerate() {
            if i > 0 {
                lines.push(Vec::new());
                used = 0.0;
            }
            for word in para.split_inclusive(' ') {
                let ww = measure(word.trim_end());
                if used > 0.0 && used + ww > w + 0.5 {
                    if let Some(last) = lines.last_mut().and_then(|l| l.last_mut()) {
                        let t = last.0.trim_end().to_string();
                        last.0 = t;
                    }
                    lines.push(Vec::new());
                    used = 0.0;
                }
                let line = lines.last_mut().unwrap();
                match line.last_mut() {
                    Some(last) if last.1 == *c && !last.0.starts_with('\u{1}') => last.0.push_str(word),
                    _ => line.push((word.to_string(), *c)),
                }
                used += measure(word);
            }
        }
    }
    // (no empty line at the end of a text that ends with its line break)
    while lines.len() > 1 && lines.last().is_some_and(|l| l.iter().all(|(s, _)| s.trim().is_empty())) {
        lines.pop();
    }
    lines
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_at_spaces_and_breaks() {
        let m = |s: &str| s.chars().count() as f32;
        let spans = vec![("aaa bbb\nccc".to_string(), [1.0; 3]), ("\u{1}icon".to_string(), [1.0; 3]), (" dd".to_string(), [0.5; 3])];
        let lines = wrap(&spans, 5.0, &m);
        let text: Vec<String> = lines.iter().map(|l| l.iter().map(|(s, _)| s.as_str()).collect()).collect();
        assert_eq!(text[0], "aaa");
        assert_eq!(text[1], "bbb");
        assert!(text[2].starts_with("ccc"));
    }
}
