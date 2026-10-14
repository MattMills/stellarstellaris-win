//! The game's binary meshes (`gfx/models/**/*.mesh`, Clausewitz "pdxasset" binary). Read from the
//! files (docs/render.md section 7):
//!
//! - the file starts with the 4 bytes `@@b@`;
//! - an object: `[` repeated depth times (1 for the top level), then its name, NUL-terminated;
//!   it holds what follows until an object of the same or a lower depth;
//! - a property of the object before it: `!`, the name's length (one byte), the name, the type
//!   (`i` int32, `f` float32, `s` strings), a u32 count, then the values (each string: a u32
//!   length, then the bytes, NUL included). Little-endian.
//!
//! The tree: `!pdxasset i[2]` (1, 0: the version), `[object]` with one child per shape (Maya's
//! shape names), each with `[mesh]` children (the sub-meshes: `p` positions xyz, `n` normals,
//! `ta` tangents xyzw, `u0` (`u1`...) uvs, `tri` triangles, and the children `[aabb]` (`min`,
//! `max`), `[material]` (`shader`, `diff`, `n`, `spec`), `[skin]` (`bones`: weights per vertex,
//! `ix`, `w`: four per vertex)) and a `[skeleton]` (one child per bone: `ix`, `pa` the parent,
//! `tx` a 3x4 matrix); `[locator]` with one child per locator (`p`, `q` a quaternion, `pa` a
//! parent bone).

use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug)]
pub enum Value {
    Int(Vec<i32>),
    Float(Vec<f32>),
    Str(Vec<String>),
}

impl Value {
    pub fn floats(&self) -> &[f32] {
        match self {
            Value::Float(v) => v,
            _ => &[],
        }
    }
    pub fn ints(&self) -> &[i32] {
        match self {
            Value::Int(v) => v,
            _ => &[],
        }
    }
    pub fn first_str(&self) -> Option<&str> {
        match self {
            Value::Str(v) => v.first().map(String::as_str),
            _ => None,
        }
    }
    fn kind(&self) -> char {
        match self {
            Value::Int(_) => 'i',
            Value::Float(_) => 'f',
            Value::Str(_) => 's',
        }
    }
    #[allow(dead_code)]
    fn len(&self) -> usize {
        match self {
            Value::Int(v) => v.len(),
            Value::Float(v) => v.len(),
            Value::Str(v) => v.len(),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Node {
    pub name: String,
    pub props: Vec<(String, Value)>,
    pub children: Vec<Node>,
}

impl Node {
    pub fn prop(&self, name: &str) -> Option<&Value> {
        self.props.iter().find(|(n, _)| n == name).map(|(_, v)| v)
    }
    pub fn child(&self, name: &str) -> Option<&Node> {
        self.children.iter().find(|c| c.name == name)
    }
}

/// The tree of a file: a root (depth 0) holding the top-level properties and objects.
pub fn parse(d: &[u8]) -> Result<Node, String> {
    if d.len() < 4 || &d[..4] != b"@@b@" {
        return Err("not a binary pdxasset (no @@b@)".into());
    }
    let mut stack: Vec<Node> = vec![Node::default()];
    let mut i = 4;
    let u32_at = |i: usize| -> Result<u32, String> {
        d.get(i..i + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).ok_or(format!("truncated at {i}"))
    };
    while i < d.len() {
        match d[i] {
            b'[' => {
                let mut depth = 0;
                while i < d.len() && d[i] == b'[' {
                    depth += 1;
                    i += 1;
                }
                let end = d[i..].iter().position(|&b| b == 0).ok_or(format!("unterminated name at {i}"))? + i;
                let name = String::from_utf8_lossy(&d[i..end]).into_owned();
                i = end + 1;
                // close the objects at this depth or deeper
                while stack.len() > depth {
                    let done = stack.pop().unwrap();
                    stack.last_mut().unwrap().children.push(done);
                }
                if stack.len() != depth {
                    return Err(format!("object {name:?} at depth {depth} under depth {}", stack.len() - 1));
                }
                stack.push(Node { name, ..Default::default() });
            }
            b'!' => {
                let n = *d.get(i + 1).ok_or("truncated property")? as usize;
                let name = String::from_utf8_lossy(d.get(i + 2..i + 2 + n).ok_or("truncated property name")?).into_owned();
                i += 2 + n;
                let kind = *d.get(i).ok_or("truncated property type")?;
                let count = u32_at(i + 1)? as usize;
                i += 5;
                let value = match kind {
                    b'i' => {
                        let b = d.get(i..i + 4 * count).ok_or(format!("truncated ints of {name}"))?;
                        i += 4 * count;
                        Value::Int(b.chunks(4).map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
                    }
                    b'f' => {
                        let b = d.get(i..i + 4 * count).ok_or(format!("truncated floats of {name}"))?;
                        i += 4 * count;
                        Value::Float(b.chunks(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
                    }
                    b's' => {
                        let mut v = Vec::with_capacity(count);
                        for _ in 0..count {
                            let len = u32_at(i)? as usize;
                            i += 4;
                            let s = d.get(i..i + len).ok_or(format!("truncated string of {name}"))?;
                            i += len;
                            v.push(String::from_utf8_lossy(s).trim_end_matches('\0').to_string());
                        }
                        Value::Str(v)
                    }
                    other => return Err(format!("property {name}: type {:?} at {}", other as char, i - 5)),
                };
                stack.last_mut().unwrap().props.push((name, value));
            }
            other => return Err(format!("byte {other:#04x} at {i}: neither [ nor !")),
        }
    }
    while stack.len() > 1 {
        let done = stack.pop().unwrap();
        stack.last_mut().unwrap().children.push(done);
    }
    Ok(stack.pop().unwrap())
}

#[derive(Clone, Debug, Default)]
pub struct Material {
    pub shader: String,
    pub diffuse: String,
    pub normal: String,
    pub specular: String,
}

#[derive(Clone, Debug)]
pub struct Skin {
    /// influences per vertex used (the slots are always 4)
    pub bones: i32,
    pub ix: Vec<i32>,
    pub w: Vec<f32>,
}

#[derive(Clone, Debug)]
pub struct SubMesh {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub tangents: Vec<[f32; 4]>,
    pub uv0: Vec<[f32; 2]>,
    /// further uv sets (u1, u2 ...)
    pub uv_sets: usize,
    pub indices: Vec<u32>,
    pub aabb: ([f32; 3], [f32; 3]),
    pub material: Material,
    pub skin: Option<Skin>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct Bone {
    pub name: String,
    pub ix: i32,
    pub parent: Option<i32>,
    /// a 3x4 matrix (the inverse bind pose: 3 rows of a rotation and the translation)
    pub tx: [f32; 12],
}

#[derive(Clone, Debug)]
pub struct Shape {
    pub name: String,
    pub meshes: Vec<SubMesh>,
    pub skeleton: Vec<Bone>,
}

#[derive(Clone, Debug)]
pub struct Locator {
    pub name: String,
    pub p: [f32; 3],
    pub q: [f32; 4],
    pub parent: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Mesh {
    pub version: Vec<i32>,
    pub shapes: Vec<Shape>,
    pub locators: Vec<Locator>,
}

fn chunks3(v: &[f32]) -> Vec<[f32; 3]> {
    v.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect()
}

fn sub_mesh(m: &Node) -> SubMesh {
    let f = |n: &str| m.prop(n).map(|v| v.floats().to_vec()).unwrap_or_default();
    let positions = chunks3(&f("p"));
    let mut normals = chunks3(&f("n"));
    let mut tangents: Vec<[f32; 4]> = f("ta").chunks_exact(4).map(|c| [c[0], c[1], c[2], c[3]]).collect();
    let mut uv0: Vec<[f32; 2]> = f("u0").chunks_exact(2).map(|c| [c[0], c[1]]).collect();
    let nv = positions.len();
    normals.resize(nv, [0.0, 1.0, 0.0]);
    tangents.resize(nv, [1.0, 0.0, 0.0, 1.0]);
    uv0.resize(nv, [0.0, 0.0]);
    let uv_sets = (0..8).filter(|k| m.prop(&format!("u{k}")).is_some()).count();
    let indices = m.prop("tri").map(|v| v.ints().iter().map(|&i| i.max(0) as u32).collect()).unwrap_or_default();
    let aabb = m
        .child("aabb")
        .map(|a| {
            let g = |n: &str| a.prop(n).map(|v| v.floats().to_vec()).unwrap_or_default();
            let (lo, hi) = (g("min"), g("max"));
            ([lo.first().copied().unwrap_or(0.0), lo.get(1).copied().unwrap_or(0.0), lo.get(2).copied().unwrap_or(0.0)],
             [hi.first().copied().unwrap_or(0.0), hi.get(1).copied().unwrap_or(0.0), hi.get(2).copied().unwrap_or(0.0)])
        })
        .unwrap_or(([0.0; 3], [0.0; 3]));
    let material = m
        .child("material")
        .map(|mat| {
            let s = |n: &str| mat.prop(n).and_then(Value::first_str).unwrap_or("").to_string();
            Material { shader: s("shader"), diffuse: s("diff"), normal: s("n"), specular: s("spec") }
        })
        .unwrap_or_default();
    let skin = m.child("skin").map(|s| Skin {
        bones: s.prop("bones").and_then(|v| v.ints().first().copied()).unwrap_or(0),
        ix: s.prop("ix").map(|v| v.ints().to_vec()).unwrap_or_default(),
        w: s.prop("w").map(|v| v.floats().to_vec()).unwrap_or_default(),
    });
    SubMesh { positions, normals, tangents, uv0, uv_sets, indices, aabb, material, skin }
}

/// Reads a mesh file.
pub fn load(path: &str) -> Result<Mesh, String> {
    let d = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    let root = parse(&d).map_err(|e| format!("{path}: {e}"))?;
    let version = root.prop("pdxasset").map(|v| v.ints().to_vec()).unwrap_or_default();
    let mut shapes = Vec::new();
    if let Some(obj) = root.child("object") {
        for s in &obj.children {
            let meshes = s.children.iter().filter(|c| c.name == "mesh").map(sub_mesh).collect();
            let skeleton = s
                .child("skeleton")
                .map(|sk| {
                    sk.children
                        .iter()
                        .map(|b| {
                            let tx = b.prop("tx").map(|v| v.floats().to_vec()).unwrap_or_default();
                            let mut m = [0.0f32; 12];
                            for (k, x) in tx.iter().take(12).enumerate() {
                                m[k] = *x;
                            }
                            Bone {
                                name: b.name.clone(),
                                ix: b.prop("ix").and_then(|v| v.ints().first().copied()).unwrap_or(-1),
                                parent: b.prop("pa").and_then(|v| v.ints().first().copied()),
                                tx: m,
                            }
                        })
                        .collect()
                })
                .unwrap_or_default();
            shapes.push(Shape { name: s.name.clone(), meshes, skeleton });
        }
    }
    let mut locators = Vec::new();
    if let Some(loc) = root.child("locator") {
        for l in &loc.children {
            let p = l.prop("p").map(|v| v.floats().to_vec()).unwrap_or_default();
            let q = l.prop("q").map(|v| v.floats().to_vec()).unwrap_or_default();
            locators.push(Locator {
                name: l.name.clone(),
                p: [p.first().copied().unwrap_or(0.0), p.get(1).copied().unwrap_or(0.0), p.get(2).copied().unwrap_or(0.0)],
                q: [q.first().copied().unwrap_or(0.0), q.get(1).copied().unwrap_or(0.0), q.get(2).copied().unwrap_or(0.0), q.get(3).copied().unwrap_or(1.0)],
                parent: l.prop("pa").and_then(Value::first_str).map(str::to_string),
            });
        }
    }
    Ok(Mesh { version, shapes, locators })
}

/// Reads every .mesh under the directories and describes what the format holds: the paths of
/// the tree (shape and bone names as `*`), their types and counts, and what the files use.
pub fn census(dirs: &[String]) -> String {
    fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("mesh")) {
                out.push(p);
            }
        }
    }
    let mut files = Vec::new();
    for d in dirs {
        walk(std::path::Path::new(d), &mut files);
    }
    let t0 = std::time::Instant::now();
    // path -> (files, occurrences, types, counts' remainders mod 2/3/4)
    let mut paths: BTreeMap<String, (usize, usize, BTreeSet<char>)> = BTreeMap::new();
    let mut failed = Vec::new();
    let (mut skinned, mut max_bones, mut submeshes, mut tris, mut verts) = (0usize, 0i32, 0usize, 0usize, 0usize);
    let mut uv_sets: BTreeMap<usize, usize> = BTreeMap::new();
    let mut shaders: BTreeMap<String, usize> = BTreeMap::new();
    let mut versions: BTreeMap<String, usize> = BTreeMap::new();
    let mut lod_names = 0usize;
    let mut checks_failed = Vec::new();
    for f in &files {
        let path = f.to_string_lossy().into_owned();
        let d = match std::fs::read(f) {
            Ok(d) => d,
            Err(e) => {
                failed.push(format!("{path}: {e}"));
                continue;
            }
        };
        let root = match parse(&d) {
            Ok(r) => r,
            Err(e) => {
                failed.push(format!("{path}: {e}"));
                continue;
            }
        };
        let mut seen: BTreeSet<String> = BTreeSet::new();
        fn visit(n: &Node, prefix: &str, depth: usize, seen: &mut BTreeSet<String>, paths: &mut BTreeMap<String, (usize, usize, BTreeSet<char>)>) {
            for (name, v) in &n.props {
                let key = format!("{prefix}!{name}");
                let e = paths.entry(key.clone()).or_default();
                e.1 += 1;
                e.2.insert(v.kind());
                seen.insert(key);
            }
            for c in &n.children {
                // shapes, locators and bones: their names vary
                let generic = match (prefix, depth) {
                    ("/object", 1) | ("/locator", 1) => "*".to_string(),
                    _ if prefix.ends_with("/skeleton") => "*".to_string(),
                    _ => c.name.clone(),
                };
                let p = format!("{prefix}/{generic}");
                let e = paths.entry(p.clone()).or_default();
                e.1 += 1;
                seen.insert(p.clone());
                visit(c, &p, depth + 1, seen, paths);
            }
        }
        visit(&root, "", 0, &mut seen, &mut paths);
        for s in &seen {
            paths.get_mut(s).unwrap().0 += 1;
        }
        let version = root.prop("pdxasset").map(|v| format!("{:?}", v.ints())).unwrap_or("none".into());
        *versions.entry(version).or_default() += 1;
        if let Ok(m) = load(&path) {
            for s in &m.shapes {
                if s.name.to_lowercase().contains("lod") {
                    lod_names += 1;
                }
                for sm in &s.meshes {
                    submeshes += 1;
                    tris += sm.indices.len() / 3;
                    verts += sm.positions.len();
                    *shaders.entry(sm.material.shader.clone()).or_default() += 1;
                    *uv_sets.entry(sm.uv_sets).or_default() += 1;
                    if let Some(sk) = &sm.skin {
                        skinned += 1;
                        max_bones = max_bones.max(sk.bones);
                        if sk.ix.len() != sm.positions.len() * 4 || sk.w.len() != sm.positions.len() * 4 {
                            checks_failed.push(format!("{path} {}: skin {} ix, {} w for {} vertices", s.name, sk.ix.len(), sk.w.len(), sm.positions.len()));
                        }
                    }
                    let n = sm.positions.len() as u32;
                    if sm.indices.len() % 3 != 0 || sm.indices.iter().any(|&i| i >= n) {
                        checks_failed.push(format!("{path} {}: {} indices for {} vertices", s.name, sm.indices.len(), n));
                    }
                }
            }
        }
    }
    let mut out = format!(
        "{} .mesh files read in {:.1} s, {} failed; {submeshes} sub-meshes, {verts} vertices, {tris} triangles; {skinned} skinned (at most {max_bones} bones per vertex); {lod_names} shapes named like a LOD\n",
        files.len(),
        t0.elapsed().as_secs_f64(),
        failed.len()
    );
    out += &format!("versions (pdxasset): {versions:?}\nuv sets per sub-mesh: {uv_sets:?}\n");
    let mut sh: Vec<_> = shaders.into_iter().collect();
    sh.sort_by(|a, b| b.1.cmp(&a.1));
    out += &format!("shaders ({}): {}\n", sh.len(), sh.iter().take(40).map(|(s, n)| format!("{s} {n}")).collect::<Vec<_>>().join(", "));
    out += "the tree (path: files, occurrences, types):\n";
    for (p, (files_n, occ, types)) in &paths {
        let t: String = types.iter().collect();
        out += &format!("  {p:<40} {files_n:>6} {occ:>8} {t}\n");
    }
    for f in failed.iter().take(10) {
        out += &format!("  failed: {f}\n");
    }
    out += &format!("index and skin checks failed: {}\n", checks_failed.len());
    for c in checks_failed.iter().take(10) {
        out += &format!("  {c}\n");
    }
    out
}
