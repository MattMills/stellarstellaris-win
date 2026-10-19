# Script and asset loading: ours, the game's, and live reload

How the simulation and the renderer find, read and parse the game's files, how the 4.5.2 game
does it (read in the Linux binary, `/opt/stellaris-headless/re` on 10.5.0.24), and a design for
reloading changed files quickly on both the PDXScript side and the Lua side.

We don't want to load the way the game does (its databases are C++ objects built once in a fixed
order). We do want to be able to **match** it: the same files, in the same order, with the same
override rules. On top of that we want file change notifications, so a changed file reloads only
what depends on it.

[V] marks what was read in the binary, and [I] what is inferred.

## 1. How we load today

| loader | what | how it lists | mods |
|---|---|---|---|
| `lua/stellar/script/source.lua` | the file layer under everything else: `filesystem`, `files`, `parse`, `definitions`, `expand` (inline scripts), `instantiate` (scripted trigger/effect/value templates) | `FS:files(subdir, ext)`: one folder, not recursive, sorted by name, deduplicated case-insensitively | yes, via `source.filesystem(game_dir, mods)` (later root wins, `replace_path` honoured); **a bare `game_dir` string means no mods** |
| `sim/lua/engine/defs.lua` | every folder of `common/`: `defs.folder`, `defs.get` | the folders come from `RUST.list_files(game_dir, "common")` (**vanilla only**, recursive), then `source.definitions` per folder | only for files in folders vanilla already has |
| `sim/lua/simscript/db.lua` | events, on_actions (merged), scripted triggers/effects/values, static modifiers, scripted variables, file variables | events with `RUST.list_files(game_dir, "events")` (**vanilla only, recursive**); the rest with `source.definitions` | through `db.fs` |
| `sim/lua/engine/localisation.lua` | `localisation/<language>/*.yml` | `RUST.list_files` (vanilla only) | no |
| `sim/render/lua/render/gfx.lua` and `gui.lua` | `.gfx` and `.gui` under `interface/` and `gfx/` | `RENDER_SUBDIRS` (Rust, recursive, vanilla) | no |
| `sim/render/src/*.rs` | textures (`dds.rs`, `Cache` in `gui.rs`), meshes (`pdxmesh.rs`, `models.rs`), fonts, particle effects, bindings | `std::fs` directly | no |
| render windows (`render/windows/*.lua`, `creator_*.lua`, ...) | whatever each window needs: defines, traits, component templates, scripted variables, diplo phrases, ... | `source.files(game_dir, ...)` / `source.parse(game_dir, ...)` | **no** (they pass `game_dir`) |

Findings:
- **272 call sites** of `source.parse` / `source.files` / `source.definitions` / `pdxscript.parse`. Nothing caches a parse by file, so the same files are parsed many times. For example, `common/scripted_variables` is parsed separately by `fleet.lua`, `technology.lua`, `planet.lua` and `db.lua`. `db.lua` also parses `common/scripted_triggers`, `scripted_effects` and `script_values` again after `defs.load` has already read them.
- **Mods** reach only what goes through `db.fs` / `defs.fs`. Events, localisation, GUI, gfx, textures, meshes and every window's own reads see vanilla only. A folder that only a mod has is never listed, because `defs.load` lists the folders from vanilla.
- **Order:** our sort (Lua `table.sort` on names) is the game's: a byte compare, then length (below). Our deduplication is case-insensitive and the game's is exact. That's the same on Windows, but not on Linux.
- **Depth:** the game reads some folders recursively (inline_scripts, name_lists, defines, terraform, solar_system_initializers, global_ship_designs, map/setup_scenarios, localisation, gfx, interface) and the rest at depth 0. We read `common/` folders at depth 0 and events recursively.
  - In vanilla this only matters for `inline_scripts`, which has 57 subfolders and is read by path anyway.
  - With mods it matters: files a mod nests under `common/terraform/x/` are read by the game and not by us.
- **Duplicate keys:** `source.definitions` keeps the last definition (LIOS), as the game does for all its single-object databases (below). The game reloads the new definition into the old one's slot; we replace the table entry.

## 2. How the game loads (4.5.2) [V]

### The file system
- A virtual file system over PhysFS (`VFSEnumerateFiles`, `VFSOpenFile`, `PHYSFS_enumerate`). Mods are mount points over the game directory, and the same relative path in a later mount replaces the file.
- **Pre-enumeration:** at start, `RunGame` calls `VFSPreEnumerateFiles(folder, extension, pattern2, depth)` for 239 folders. Each one is a task on the job scheduler, which lists the folder and opens its files ahead of time. A database then calls `VFSGetEnumeratedFiles(folder, ...)`: it finds the folder's task in a hash map, waits for it, and takes its list. It falls back to `VFSEnumerateFiles` (with a log line) for a folder that wasn't pre-enumerated.
  - 194 folders are listed with no extension at depth 0: most of `common/`.
  - 17 are listed `.txt` at depth 0, including `events`, `prescripted_countries`, `common/planet_classes`, `common/component_templates` and `common/game_rules`.
  - These are listed `.txt` with unlimited depth (-1): `music`, `common/inline_scripts` (no extension), `common/name_lists`, `common/defines`, `unchecked_defines`, `map/galaxy`, `common/terraform`, `common/solar_system_initializers`, `map/setup_scenarios` and `common/global_ship_designs`.
  - Localisation is listed `.yml` at depth -1: `localisation` and `pdx_online_assets/localisation`.
  - The interface is listed `.gfx` and `.gui` at depth -1: `interface`, `gfx` and `pdx_online_assets/interface`, with a `load_screen` pass first.
  - Portraits and loading screens are listed `.dds` and `.txt`.
- **A listing** (`VFSEnumerateFiles` → `EnumerateFilesRecursive(folder, out, ext, pattern, prefix, depth, max)`) collects the relative paths, `std::stable_sort`s them with `CString::operator<` (`memcmp` over the shorter length, then the shorter first: byte order, case-sensitive), and removes exact duplicates (`std::unique`).

### The databases
- `NNullObjAndDatabaseInitUtil::SetupDatabases` fills a table of 198 databases (`SDatabaseObjectFunctions`: name, CreateInstance, DestroyInstance, CanInitialize, InitInstance, PostReadInitInstance). It runs them in dependency order: the first one left whose `CanInitialize` holds, or that has none. Deferred key references are resolved next, then every `PostReadInitInstance`.
  - The table starts: named colors, galaxy shapes, static modifiers, scripted trigger, effect and value templates, asteroid belts, weapon / job / trait tags, strategic resources, ...
  - `lua/stellar/databases.lua` reads the same table on Windows.
- 164 of them are `TSingleObjectGameDatabase<DB, Object, bool>`. Its `Init()`:
  1. calls `VFSGetEnumeratedFiles(folder, out, nullptr, nullptr, 0)`;
  2. calls `LoadFile(path, reload)` for each file;
  3. calls `AttachFileWatcher()`.
- `LoadFromReader(reader, reload)`: for each top-level `key = {`, a new key goes to `ReadNewEntry`, and a key already in the database to `ReadExistingEntry(reader, key, existing, reload)`:
  1. Unless `reload`, it logs `Object with key: %s already exists, using the one at %s` (the location of the new one).
  2. It runs the old object's destructor, `memset`s it and constructs it again **with its old index**.
  3. It reads the new definition into it.

  So the last definition wins, and the object keeps the first one's slot and index: pointers and indices held elsewhere stay valid.
  - `inline_script` statements open their own reader (`CreateInlineScriptReader`) while the file is read.
  - The template's bool is `true` for 7 databases (event chains, frontend backgrounds, leader classes, ship sizes, star classes, technology categories, technology) and `false` for 157. Both kinds replace in place; what the bool switches isn't settled.

### Localisation
`PdxLocalizeReadFolder` → `ReadLocalizationFolderHelper(folder, language, ...)` →
`LocalizeAddLocalization`:
1. It lists the folder's `.yml` files at every level (`localisation`, `pdx_online_assets/localisation`).
2. It keeps the files whose path contains the current language's tag (`LocalizeGetCurrentLanguage`, `l_english`).
3. It reads the files outside a replace folder first. A key defined twice keeps its first text, and the log says `Discarded duplicate key: ...`.
4. It reads the files with `/replace/` in their path next, and their texts replace any before.
5. The keys are sorted after each pass.

A file without a UTF-8 BOM is still read; the log notes `should be in utf-8-bom encoding`.

### Reloading
- **File watching is compiled out of the release build.**
  - `CGameApplication::InitFileWatchers` and `InitializePdxLocalizeFileWatcher` are a bare `ret`.
  - `CSingleObjectGameDatabaseBase::AttachFileWatcher` builds the folder string and drops it.
  - `inotify` is used only by SDL's device hotplug.
  - The flag `g_bFileWatcherEnabled` and its console command (`OnExecute_FileWatcher`) remain.
- **What remains is the reload path the watcher would have used.** `CSingleObjectGameDatabaseBase::FileWatcherCallback(void*, path)`:
  1. reloads the database's file (`LoadFile(path, reload = true)`: in place, without the duplicate warning);
  2. runs `CTriggerDatabase::PostInit`, `CTriggerDatabase::PostValidate` and `CEffectDatabase::PostInit` again, which rebuilds the scripted triggers and effects called with arguments.

  The galaxy template database has its own callback.
- **Manual reloads:** `CReloadManager` keeps reloaders (`CReloadDispatcher`) by name, and `CClausewitzReloadManager::Reload(targets)` runs them.
  - The registered names include `defines`, `texture`, `mesh`, `particle`, `anim`, `guianim`, `worldgfx` and `stats` (ship stats). Assets, audio and font reloaders exist as classes too.
  - The console commands are `reloadgui` (`CGui::ReloadFolder`), `reloadfx`, `reload_deeds` and `reloadgraphicalmap`.
  - Apart from defines and ship stats, **no `common/` database can be reloaded at run time** in the shipped game.

## 3. Design

### 3.1 One file system, shared by Rust and Lua
A Rust `Vfs`, created once and used by the sim, the renderer's Rust and the Lua (as `RUST.vfs_*`):
- **Mounts:** the game directory, then the enabled mods in launcher order (`dlc_load.json`, descriptors with `path` and `replace_path`), as `source.enabled_mods` reads them today. The same relative path in a later mount wins, and `replace_path` hides earlier mounts' files in that folder.
- **`list(folder, ext, depth)` with the game's rules:** byte-order sort, exact deduplication, and the game's depth per folder from a table of the pre-enumerated folders (folder, extension, depth). That table is generated from the binary like the docs dump and isn't game data. A folder the table doesn't have is depth 0, as the game's fallback is.
- **`read(path)`:** the file's bytes, cached by `(mount, relative path)` together with its size, modification time and a content hash. Startup can list and read in parallel, as the game's pre-enumeration does.
- **`resolve(path)`:** which mount's file wins, so a change to a file that is overridden is ignored.

`source.lua` keeps its interface but sits on the `Vfs`. A bare `game_dir` then means "the session's file system with its mods", not "vanilla only", which fixes every window's reads at once.

### 3.2 One parse cache
`source.parse(fs, path)` is memoized by `(path, version)`, where `version` is the `Vfs` file's hash. Every reader goes through it:
- the 272 call sites keep calling `source.parse`, but parse each file once per change instead of once per caller;
- `db.lua` takes the scripted triggers, effects and values from `defs` rather than parsing them again;
- the window modules that read `common/scripted_variables` take them from `db`.

### 3.3 Dependency index
Each product records the files it was built from, so a change invalidates only what read the file:

| product | built from | on change |
|---|---|---|
| `defs.folders[folder][key]` | the file each key came from (and the other files that define the same key, in order) | re-read that file; replace its keys in place (keep the table, as the game keeps the index); a key the file no longer defines falls back to the previous file that defines it, else goes away |
| scripted trigger / effect / value templates and their instantiations (`source.instantiate`, `db.instance`) | the definition's file | drop the template's instantiation cache: the game's `PostInit` again, for those definitions only |
| inline script expansions (`source.expand`, `defs` `expanded`) | the including file and every inline script file it pulled in | reverse index inline script → including definitions; expand those again |
| scripted variables (`@x`) | `common/scripted_variables` (global) and each file's own | file variables: that file only; a global variable: the definitions whose blocks name it (an index built at parse time) |
| compiled closures (`simscript/compile.lua`, keyed by block) | the block | a new block is a new key; the old closures are collected (they're weak) |
| events and on_actions (`db.events`, `db.on_actions`) | the event file; every on_actions file (they merge) | re-read the event file; for on_actions, rebuild the merged table |
| localisation | each `.yml` | re-read that file, replace its keys |
| GUI and sprites (`render.gfx`, `render.gui`) | each `.gfx` / `.gui` | re-read that file; rebuild the windows that use its types (the game's `reloadgui`) |
| textures, meshes, fonts, particles (Rust caches) | each file | drop the cache entry; the next draw loads it (the game's `texture`, `mesh`, `particle` reloaders) |
| defines | `common/defines` | re-read; the systems that copied a define read it again (the game's `defines` reloader) |

### 3.4 Change notifications
- A watcher in Rust (the `notify` crate: inotify on Linux, `ReadDirectoryChangesW` on Windows) over every mount.
- It debounces events (editors write in several steps), maps each path to `(mount, relative path)`, and keeps it only if that file is the winning one.
- Created, deleted and renamed files also update the affected folder's listing; modified files don't need a re-list.
- The Lua drains the queue at a frame boundary (`RUST.vfs_changes()`) and runs the reloads in 3.3, in a fixed order:
  1. listings;
  2. parses;
  3. definitions;
  4. templates and inline scripts;
  5. events and on_actions;
  6. localisation;
  7. GUI;
  8. assets.

  The simulation never sees a half-reloaded state.
- **Cost:** a changed file is one read and one parse, plus its dependents. Re-reading a folder or all of `common/` is never needed for a content change.

### 3.5 Matching the game
- A **match mode** loads exactly as the game does. That means:
  - the pre-enumeration table's folders, extensions and depths;
  - byte-order listing with exact deduplication;
  - last-wins duplicates, with the game's `Object with key: ... already exists` line for each;
  - the databases in the game's dependency order (`SetupDatabases` and `CanInitialize`).

  We can then diff our load log against the game's `error.log` for the same mods, and our definition set against the game's.
- **Live reload goes further than the game.** The game's reload only ever adds or replaces (an object is never removed), and it isn't in the release build at all. Ours also handles removed keys and removed files, and covers every folder.

## 4. Open questions for more RE
- How each database's `CanInitialize` dependencies are declared, to reproduce the exact database order in match mode. `lua/stellar/databases.lua` reads them on Windows.
- The VFS mount code: mod order, `replace_path`, and the DLC folders (`dlc/*/`).
- What the `bool` of `TSingleObjectGameDatabase` switches.
- Whether `FileWatcherCallback` removes keys a file no longer defines (the reload path reads like it doesn't).

## 5. Steps
1. The `Vfs` in Rust plus `source.lua` on top of it; the parse cache. No behaviour change except mods now reaching every reader. Check: the definition counts and the scriptcheck numbers are unchanged without mods. (PR #99)
2. Fix the listing differences: folders that only a mod has, the game's depth per folder, events at depth 0, localisation from all of `localisation/`. (PR #99)
3. The dependency index and the per-product reloads (3.3), triggered by hand first (a console command, as the game's `reload`).
4. The watcher and the change queue.
5. The renderer's Rust caches on the `Vfs` (textures, meshes, fonts, particles).
6. Match mode and the load-log diff against the game.
