//! Checks a rendered map by reading the PNG back from disk: what its pixels are (background,
//! each owner's colour, unowned grey, lanes), whether every system's disc is where its
//! coordinates put it with the colour of its owner, and whether every lane is drawn.

use crate::galaxy::Galaxy;
use crate::render::{Layout, Style};

pub struct Check {
    pub width: u32,
    pub height: u32,
    pub background: usize,
    pub unowned: usize,
    pub lane: usize,
    /// antialiased edges and blends: neither the background nor a colour drawn
    pub other: usize,
    /// pixels of each country's colour, by index into `Galaxy::countries` (countries that share a
    /// colour have the same count)
    pub per_country: Vec<usize>,
    /// the owners' distinct colours, and the pixels of any of them
    pub colours: usize,
    pub coloured: usize,
    pub countries_visible: usize,
    pub systems: usize,
    /// systems whose centre pixel has the colour of the disc drawn last over it
    pub systems_ok: usize,
    /// of those, systems whose own colour is the one seen (not covered by a later disc)
    pub systems_own_colour: usize,
    pub lanes: usize,
    /// lanes whose middle is not under a disc, and of those, how many are drawn there
    pub lanes_checked: usize,
    pub lanes_ok: usize,
    /// the drawn pixels' bounding box: x0, y0, x1, y1
    pub bbox: (u32, u32, u32, u32),
}

fn bytes(c: [f32; 3]) -> [u8; 3] {
    [(c[0] * 255.0).round() as u8, (c[1] * 255.0).round() as u8, (c[2] * 255.0).round() as u8]
}

fn near(p: &[u8], c: [u8; 3]) -> bool {
    (0..3).all(|i| (p[i] as i32 - c[i] as i32).abs() <= 1)
}

/// Reads an RGBA8 (or RGB8) PNG.
pub fn read_png(path: &str) -> Result<(u32, u32, Vec<u8>), String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?;
    let decoder = png::Decoder::new(std::io::BufReader::new(file));
    let mut reader = decoder.read_info().map_err(|e| format!("{path}: {e}"))?;
    let mut buf = vec![0; reader.output_buffer_size().ok_or("png: no buffer size")?];
    let info = reader.next_frame(&mut buf).map_err(|e| format!("{path}: {e}"))?;
    buf.truncate(info.buffer_size());
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf.chunks(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        other => return Err(format!("{path}: colour type {other:?}")),
    };
    Ok((info.width, info.height, rgba))
}

/// Writes RGBA8 pixels as a PNG.
pub fn write_png(path: &str, width: u32, height: u32, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| format!("{path}: {e}"))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| format!("{path}: {e}"))?;
    writer.write_image_data(rgba).map_err(|e| format!("{path}: {e}"))?;
    writer.finish().map_err(|e| format!("{path}: {e}"))?;
    Ok(())
}

pub fn check(path: &str, galaxy: &Galaxy, layout: &Layout, style: &Style) -> Result<Check, String> {
    let (width, height, px) = read_png(path)?;
    if (width, height) != (layout.width, layout.height) {
        return Err(format!("{path}: {width}x{height}, rendered {}x{}", layout.width, layout.height));
    }
    let at = |x: u32, y: u32| -> &[u8] {
        let i = (y as usize * width as usize + x as usize) * 4;
        &px[i..i + 3]
    };
    let bg = bytes(style.background);
    let lane = bytes(style.lane);
    let unowned = bytes(style.unowned);
    let country: Vec<[u8; 3]> = galaxy.countries.iter().map(|c| bytes(style.owner_colour(c.rgb))).collect();
    // countries can share a colour: pixels are counted per colour, and a country's count is its
    // colour's
    let mut palette: Vec<[u8; 3]> = Vec::new();
    for &k in &country {
        if !palette.contains(&k) {
            palette.push(k);
        }
    }
    let mut per_colour = vec![0usize; palette.len()];

    // every pixel, by what it is
    let mut c = Check {
        width,
        height,
        background: 0,
        unowned: 0,
        lane: 0,
        other: 0,
        per_country: vec![0; country.len()],
        colours: 0,
        coloured: 0,
        countries_visible: 0,
        systems: galaxy.systems.len(),
        systems_ok: 0,
        systems_own_colour: 0,
        lanes: galaxy.lanes.len(),
        lanes_checked: 0,
        lanes_ok: 0,
        bbox: (u32::MAX, u32::MAX, 0, 0),
    };
    for y in 0..height {
        for x in 0..width {
            let p = at(x, y);
            if near(p, bg) {
                c.background += 1;
                continue;
            }
            c.bbox = (c.bbox.0.min(x), c.bbox.1.min(y), c.bbox.2.max(x), c.bbox.3.max(y));
            if let Some(k) = palette.iter().position(|&k| near(p, k)) {
                per_colour[k] += 1;
            } else if near(p, unowned) {
                c.unowned += 1;
            } else if near(p, lane) {
                c.lane += 1;
            } else {
                c.other += 1;
            }
        }
    }
    c.colours = palette.len();
    c.coloured = per_colour.iter().sum();
    c.per_country = country.iter().map(|k| per_colour[palette.iter().position(|p| p == k).unwrap()]).collect();
    c.countries_visible = c.per_country.iter().filter(|&&n| n > 0).count();

    // the discs, in the order they are drawn (unowned first, then owned), in pixels
    let mut order: Vec<usize> = (0..galaxy.systems.len()).collect();
    order.sort_by_key(|&i| galaxy.systems[i].owner.is_some());
    let discs: Vec<(f32, f32, f32, [u8; 3], usize)> = order
        .iter()
        .map(|&i| {
            let s = &galaxy.systems[i];
            let (x, y) = layout.to_pixel(s.x, s.y);
            let r = if s.owner.is_some() { layout.star_radius } else { layout.unowned_radius };
            (x, y, r, bytes(style.system_colour(galaxy, i)), i)
        })
        .collect();
    for &(x, y, _, own, _) in &discs {
        let (fx, fy) = (x.floor(), y.floor());
        if fx < 0.0 || fy < 0.0 || fx >= width as f32 || fy >= height as f32 {
            continue;
        }
        let (cx, cy) = (fx + 0.5, fy + 0.5);
        // the colour of the last disc that covers this pixel fully
        let mut expected = own;
        for &(dx, dy, dr, dc, _) in &discs {
            if ((cx - dx).powi(2) + (cy - dy).powi(2)).sqrt() <= dr - 0.5 {
                expected = dc;
            }
        }
        let p = at(fx as u32, fy as u32);
        if near(p, expected) {
            c.systems_ok += 1;
            if expected == own {
                c.systems_own_colour += 1;
            }
        }
    }

    // the lanes, at their middle when no disc is there
    for &(a, b) in &galaxy.lanes {
        let (sa, sb) = (&galaxy.systems[a as usize], &galaxy.systems[b as usize]);
        let (ax, ay) = layout.to_pixel(sa.x, sa.y);
        let (bx, by) = layout.to_pixel(sb.x, sb.y);
        let (mx, my) = (0.5 * (ax + bx), 0.5 * (ay + by));
        let (fx, fy) = (mx.floor(), my.floor());
        if fx < 0.0 || fy < 0.0 || fx >= width as f32 || fy >= height as f32 {
            continue;
        }
        let (cx, cy) = (fx + 0.5, fy + 0.5);
        if discs.iter().any(|&(dx, dy, dr, _, _)| ((cx - dx).powi(2) + (cy - dy).powi(2)).sqrt() <= dr + 1.5) {
            continue;
        }
        c.lanes_checked += 1;
        if !near(at(fx as u32, fy as u32), bg) {
            c.lanes_ok += 1;
        }
    }
    Ok(c)
}
