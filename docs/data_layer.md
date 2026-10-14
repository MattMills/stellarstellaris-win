# The data layer: the world and the definitions in shared memory (sim/)

The simulation runs on one LuaJIT state, and the game runs about 60% of our time in phases it
spreads over its task threads. One LuaJIT state cannot run on two threads, and Lua tables cannot
be shared between states. This document designs a store for the world (the save's tree) and the
definitions in plain memory: every Lua state of the process maps it through LuaJIT's FFI, whose
compiled field accesses are plain loads and stores. It also reports the prototype: the store, the
world API over it, exploration's daily pass on a pool of N LuaJIT states on N OS threads, and what
was measured.

Everything here was measured on 10.5.0.24 (Ryzen 9 5900X, 12 cores in two CCDs of 6, 24 threads)
from the 2210.01.01 autosave. The box was shared with other agents' runs (load 5 to 10 the whole
time), so the timings carry noise of 10 to 30%; the medians and repeats are given.

## In short

- **The store** (`sim/src/store.rs`, `sim/lua/engine/store/core.lua`): the save's tree as 16-byte
  entries (a key id, a kind, an operator, a value: a string id, a number or a block id) and 16-byte
  blocks (a contiguous range of entries and a key index). It holds the 2210 world in 1.08 M
  entries (16 MB) plus 33 MB of key index, built from the parsed tree in 0.2 s and written back
  byte for byte the same text as `pdxscript.write` (20,493,746 bytes). All 247 folders of
  definitions (21,128) take 0.3 s more and about 0.6 M entries.
- **Reads at JIT speed, if the lookup has no loop**: a key lookup is two probes of a cuckoo hash
  (10.7 ns in a compiled loop). A first version with a probe loop ran at 130 ns, because LuaJIT
  cannot compile a caller's loop through a callee's loop ("inner loop in root trace"). Against the
  table world, the raw store API is 2.5x faster on a field of every country, 6x on a three-level path
  in every fleet, 3.7x on walking a country's entries, 5.5x on a list of numbers, and 3.9x on
  every fleet's ships' hitpoints.
- **The collector**: the world's tables are 342 MB of the 915 MB Lua heap after a load, and the
  definitions' 230 MB more. With both in the store, the heap is 343 MB and a full collection takes
  610 ms instead of 1,905 ms.
- **Exploration over the store** (`engine/store/exploration.lua`, a line-by-line port of
  `engine/exploration.lua`): every country's lists, terra incognita map and surveys are identical
  to the table version on every day checked (days 0 to 6, the whole tree in the store or the
  mirror, 1 to 12 workers). On one thread the store's pass takes 22 to 36 ms, against 48 to 80 ms
  for the table pass.
- **The worker pool** (`sim/src/workers.rs`): the pass split into the game's three lambdas with a
  barrier after each, countries taken from an atomic counter, costliest first. Over repeated passes
  of the loaded world: 22 ms on 1 worker, 10 ms on 4, 8.3 ms on 8 (with long warm-up). What limits
  it: each state's own JIT warm-up (every worker compiles the same traces, seeing each country 1/N
  as often), the hardware past 6 workers (SMT siblings, two CCDs, other jobs on the box), the
  costliest country (2 ms of 15 to 25), and the serial inputs.
- **The gate**: the full 180-day diff with the store on 0, 4 and 12 workers, and with its defaults,
  equals the run without it, field path by field path (723,380 equal, 13,251 differ with today's tree; the
  same 4,725,089 draws).
- **The transition**: the rest of the engine still reads Lua tables, so the store holds a mirror
  of what exploration reads. Synced in full every day it cost about 40 ms, as much as the pool
  saved. Now the modules that write those fields mark what they changed (21 lines in 8 modules,
  section 9), the sync takes 1 to 2 ms, and `daily.countries_parallel` falls from 49 to 58 ms a day
  (tables) to 22 to 28 ms (the store, 4 workers: the pass 12 ms, its serial inputs 8 ms, ethics 1.6
  ms); 180 days take 32.7 to 33.8 s against 36.9 to 39.1 s. The store is on by default
  (`STELLAR_STORE=off` turns it off).
- **For the in-game database builder** (databases.md section 4): the definitions in the game's
  order with duplicates kept, and their file and line locations, are designed (sections 6.2 and
  6.3) and listed as open items; the prototype keeps the last definition per name and no lines.

## 1. Why

- The simulation runs about 270 ms a simulated day on one LuaJIT state (the game: 20 to 25 ms).
  About 60% of it is in phases the game runs in parallel: the modifier rebuild, the countries',
  colonies' and pop groups' days, the AI's attitudes and decisions, fleet movement.
- The game's parallel tasks write only the object they process (`...OnlyChangeSafePrivate`,
  `...SelfDontReadOthers`, docs/simulation.md section 1), so a phase can be split by object.
- Coroutines do not run in parallel. effil-style shared tables go through the C API, out of
  compiled code. Copying the world between states per phase costs more than the phase.
- The Lua heap is about 1 GB of small tables after a load (2 GB later in a run), and the
  collector is 11 to 20% of the run time (60 days: 11.5% in one run on 2026-10-13, 18.8% in
  another; the AI's work changed between them).

LuaJIT's FFI compiles `p.field` on a C struct pointer to a load. A world held as C structs in
memory every state maps is read by every thread at native speed, with no collector involved.

## 2. The store's layout

The Rust side (`store.rs`) allocates the regions once, at fixed capacities (calloc of large sizes:
the kernel commits pages as they are touched, so capacities are virtual sizes), hands out ranges
of them atomically, and interns strings under a lock. The record layout is the Lua side's
(`core.lua`, `ffi.cdef`); `store.rs` keeps the header in step.

```
pdx_entry  16 bytes   key      u32   the key's string id; 0 for a list's bare value or block
                      kind     u8    1 text, 2 number, 3 block, 4 condition ([[PARAM] ... ])
                      op       u8    1 '=' 2 '==' 3 '!=' 4 '<' 5 '>' 6 '<=' 7 '>=' 8 '?='; 0 bare
                      flags    u8    1 the key quoted, 2 the value quoted, 4 a negated condition
                      v        8     text: u.a the string id; number: num (a double); block: u.a
                                     the block id, u.b a typed block's tag (`hsv { }`)
pdx_block  16 bytes   first    u32   its first entry; its entries are first .. first + count - 1
                      count, cap     entries used, entries reserved from first
                      index    u32   its key index in the index region (0: none yet)
regions               entries, blocks, index (u32 slots), strings (bytes, offsets, lengths),
                      bytes (raw: maps, typed arrays), roots[64] (block ids: 0 the world,
                      1 the definitions, 2 the typed arrays' registry, 3 auxiliary tables),
                      counters[64] (atomic: work queues)
functions             reserve(region, n), reserve_bytes(n), intern(text), lookup(text),
                      fetch_add(slot, n): called from Lua through FFI function pointers
```

**A block's entries are contiguous.** Reading an object is a walk over consecutive 16-byte records
(a country's 102 top-level entries are 1.6 KB). A block that grows past its capacity moves to a
new range twice as large (its old entries are left behind: the store is not compacted while it
runs).

**The key index.** Every block with statements gets a two-choice (cuckoo) hash of its keys: a key
id is in slot `id & mask` or slot `((id * 40503) >> 5) & mask`, with the position of the key's
first entry. A lookup is two probes and no loop. A loop in the lookup costs a factor of 12 in a
compiled caller: LuaJIT aborts the caller's trace ("inner loop in root trace") and runs it as
separate traces connected by exits. Lists (all bare values) share one empty index. Inserts and
removals drop a block's index; it is built again on the next lookup in a serial phase (a worker
scans instead: only the main thread builds indexes of blocks others may read). The index is the
largest part of the store (33 MB for the world: 4 slots of 8 bytes per key, cuckoo tables kept at
most a quarter full); a denser layout (open addressing for the large blocks, a scan of 4 entries
for the small ones, branch-free) would halve it.

**Strings** are interned once for the process (the Rust side, under a mutex, with the bytes and
offsets in regions that never move). Each Lua state caches `id -> string` and `string -> id` in
its own tables, filled on first use, so the lock is taken once per string per state. The world
has 41,499 distinct texts; the definitions add 87,435.

**Numbers.** A token read from the save keeps its text (its string id): the save's text comes back
as it was (`1.50000` stays `1.50000`). Each state caches the number a text reads as (`tonumber`, as
`engine.world.field` does). A number the engine writes is a `number` entry holding the value the
text would read back as: `tonumber(number_text(v))`, so a read after a write gives what the table
world gives (5 decimals), and writing the save gives `number_text(v)`. (The one exception: a value
that rounds to `3.` is kept as that text, as `number_text` writes it.) The engine's numbers add no
strings, however many values a run writes.

**The save's tree onto it and back.** `S.build(tree)` maps pdxscript's forms one to one: a
statement (`key op value`) is an entry with a key and an operator; a bare token or bare block (a
list's element) an entry with key 0 and no operator; a typed block keeps its tag; a condition
(`[[PARAM] ... ]`, definitions only) is kind 4. `S.write(block)` writes what `pdxscript.write`
writes for the same tree: one entry per line, tab-indented, a block of bare tokens on one line.
For the 2210 save the two texts are identical (`engine/store/bench.lua`). Lines and comments are
not kept (`pdxscript.write` does not write them either).

**Typed arrays and object tables.** What is not the save's tree goes to typed arrays in the raw
bytes, named in a registry block (`engine/store/arrays.lua`): per-object values one phase computes
for another, rule and modifier values, the world's derived indexes. The object tables
(`engine/store/objects.lua`) are what the game's databases are: per store, the block of every
object by id, and the ids in the save's order. Some databases number from high bits (ships,
fleets: 16777216 and up), so a map keyed by ids is a dense array when the ids are dense and a
sorted array searched by halving when not (dense arrays over the ship and fleet ids took 115 ms
a day to fill before this).

## 3. The world API over the store

`engine/store/world.lua` has `engine.world`'s functions with the same signatures: `field`,
`fields`, `list`, `blocks`, `path`, `set`, `child`, `append`, `insert`, `append_value`,
`remove_value`, `remove_entry`, `remove`, `create`, `object`, `all`, `index`, `write`, `reindex`
(a no-op: the index is kept by the writes), and `find_stores` with the same naming of stores.

- A block is a handle: a `pdx_block *` cdata. `world.field` returns a token's value as
  `engine.world` does (a number when the text reads as one, else the text) and a block's handle.
  Handles compare with `==`; as table keys use `W.bid(h)` (two handles of one block are two cdata
  objects).
- `type(v) == "table"` (388 places in the engine) becomes `W.is_block(v)`.
- A Lua table given as a block (`world.append(obj, key, {})`) is copied in, and the copy's handle
  returned: code that fills a block after appending it must use the handle.
- An entry handed to `remove_entry` is an entry index (`W.find_entry`).

Under it, `engine.store.core` is the raw API converted hot code uses: block ids as numbers, key ids
looked up once (`S.id("capital")`), typed reads (`S.num`, `S.txt`, `S.blk`, `S.val`), and loops over
`B[b].first .. first + count - 1` reading `E[i]` directly. The compat API costs about twice the raw
one (the key's id looked up by string each call, the handle converted).

## 4. Writes

**In place.** `S.set` changes a token's entry (its kind and value); the block and its index are
unchanged. **Appends** go to the block's reserved capacity, or move the block to a range twice as
large; the key is added to the index (or the index dropped if full). **Inserts and removals** move
the following entries (`ffi.copy`, the save's order kept) and drop the block's index. `S.set_numbers`
rewrites a list's entries in place (growing it if needed).

**Allocation is per state.** Each state takes chunks of entries (65,536), blocks (16,384) and index
slots (16,384) from the store with an atomic add, and bump-allocates in them. A worker writing its
own objects during a parallel phase therefore allocates in its own chunks, with no lock and no
shared cache line but the counter's, once per chunk.

**In a parallel phase** the game's rule holds: a worker writes only the objects it processes. The
store adds one constraint the game's memory layout gave for free: a block other workers may be
reading must not change shape under them (a scan or an index probe of a block whose entries are
being moved reads the wrong entry). So:

1. a block only this worker reads (the country's terra incognita map, a list block of its own) is
   written freely, structurally too;
2. the entries of a block others read are changed in place only (a token's value, the child block
   a list entry points to: rewriting a list moves the list's entries, not the country's);
3. an entry added to or taken out of a block others read is handed back to the main thread
   (`D <country> <key> <values>` in the worker's result) and done after the barrier, in object
   order. This is the "per-thread arena, merged at the barrier in object order" of the plan; for
   exploration it happens a few times a day (a list appearing or emptying).

New strings interned in a parallel phase go through the interner's lock; their ids depend on the
order threads get there, which is invisible (the text is what is written and compared).

## 5. Module caches

Today's modules keep their caches in their own Lua tables. With N states each state has its own,
and what they hold decides where they go:

| cache | example (exploration) | where |
|---|---|---|
| derived from definitions, never changes | country types' flags, component templates, intel levels, the galaxy's hyperlanes and coordinates | each state builds its own on first use (cheap, read-only, immutable) |
| an object's own state across days | the terra incognita bitmap (64 KB a country), the survey lists waiting for the serial day | in the store, owned by the object (a raw-bytes record found through a map by country id), so whichever worker takes the country next day has it |
| computed in one part of a phase for another, per object | each country's intel levels (part a), read by the shared intel of other countries (part b) | a typed array in the store, one slot per object, written by the object's worker before the barrier |
| computed once per phase for everybody | the fleets that can be seen at all, with their system and owner | a typed array in the store, filled by all workers in chunks (atomic counter) in the part before the one that reads it. Computed by every worker it was 3 ms each a pass, and part c's time on 4 workers halved when it was split |
| per phase, per object | ship ranges, intel per pair of countries | each state's own, rebuilt each pass (the objects are partitioned) |
| per phase, shared, cheap | relations by country, owned systems | each state's own (duplicated: 0.2 to 0.5 ms each) |

The rule of thumb: immutable caches stay per state; mutable state belongs to an object and goes in
the store with it; a per-phase computation others read becomes a typed array produced by a
parallel sub-step.

## 6. Definitions

### 6.1 What the prototype keeps

`engine/store/defs.lua` puts every folder of `common/` that `engine.defs` read into the store as one
tree under root 1: `"common/country_types" = { default = { ... } fallen_empire = { ... } }`, each
definition its own pdxscript block (the files in load order, a later definition replacing an
earlier one, the names sorted). Built once after `engine.defs.load`: 0.30 s for 247 folders and
21,128 definitions, about 0.6 M entries and 5.3 M index slots. A worker reads a definition with
`D.get(folder, name)` and the raw API, without loading the game's files. Since nothing but
exploration reads them yet, the simulation puts only its six folders in by default (0.01 s);
`STELLAR_STORE_DEFS=all` puts every folder in.

That is enough for the simulation, which wants the definition in force. It is not enough for the
in-game builder ([databases.md](databases.md) section 4): Lua building the game's own databases
needs the game's order and duplicate rule, and the definitions' locations. The two additions
below are designed, not built (section 11's open items).

### 6.2 Addition: the game's order and duplicate rule

The game (databases.md 1.3): the folder's files in name order, the top-level statements in order
(top-level `inline_script` expanded in place), each new key an object whose `_Index` is its place
of first appearance; a key seen again replaces the object at the same index (single-object
databases) or is read into it (the six extendable ones). `engine.defs` keeps only a map of the
last definition, so the first appearance is lost.

The store keeps the folder as the game reads it, and leaves the rule to the reader:

- **The folder block holds every definition statement in load order, duplicates included**: one
  entry per top-level `key = { ... }`, as the game's `LoadFromReader` sees them (files in name order,
  inline scripts expanded). A pdxscript block may repeat a key, so this is the store's ordinary
  form: `find` gives a key's first entry, `find_next` the later ones.
- **An index array per folder** (`dbx:<folder>`, a typed array): one 16-byte record per distinct key
  in order of first appearance, `{ key id, first entry, last entry, count }`. The record's position is
  the object's `_Index`; an id map `dbk:<folder>` (key id -> position) finds it by name.
- **The rule is the reader's.** Single-object: the definition is the last entry's block, at the first
  entry's index; this is what `D.get` returns, so the simulation sees no change. Extendable: all the
  key's blocks in order (`D.blocks(folder, name)`), merged member by member by the schema as
  `ReadExistingEntry` merges them. The folder's kind comes from the schema layer (databases.md 4.3);
  the store does not need it, since it keeps everything.
- **Built by the reader that knows the order**: the definitions are read for the store by the same
  walk as `headless/dev/db/records.lua` (files sorted, statements in order, inline scripts
  expanded), not taken from `engine.defs`'s map. Checked against `records.lua`'s order and, in the
  headless game, against each database's `_Array`.
- Cost: the duplicates' blocks (few in vanilla, many with mods) and 16 bytes per definition (21,128:
  0.3 MB).

### 6.3 Addition: locations

The game's compiled objects keep "file: X line: N", its error messages name them, and the builder
hands script members to the game's compiler as the member's own lines of the original file
(databases.md section 6). So:

- **A line per entry**: a `lines` region of u32, parallel to `entries` (entry i's line is
  `lines[i]`: the line of the statement's key, pdxscript's `line`). It is reserved at the entries'
  capacity and committed only where written, which is the definitions' chunks (the world writes
  none).
- **A location per block**: a `locs` region parallel to `blocks`, 12 bytes: `{ file string id, line
  of the '{', line of the '}' }` (pdxscript's `line` and `last`), and the file of the statements an
  inline script expanded is the inline script's file, as the game's reader reports it.
- A definition's location is its block's; a script member's is its entry's line and its block's last
  line. The builder slices the original text by them (`records.lua` finds the last line by matching
  braces today). `S.write` stays one entry per line: it is the save's writer, and nothing builds
  the game's input from it.
- The moves keep them: a block that grows copies its lines with its entries, an insert or a removal
  shifts them (definitions are read-only after the load, so this is for completeness).
- API: `S.line(i)`, `S.loc(bid) -> file, first, last`. Cost: 4 bytes per definition entry and 12 per
  block, about 5 MB for the vanilla definitions.

### 6.4 Typed records

What the game's databases add are typed records (a `CCountryType` with its flags, a technology with
its cost and prerequisites resolved to indexes). Those belong in typed arrays built from the trees
once by the schema layer (databases.md 4.3): a `country_type` array of structs indexed by `_Index`
(6.2), names to indexes in a map, shared by the simulation's workers and written as C++ objects by
the in-game builder. A reference can stay a key's string id in the tree; each side resolves it in
its own world (databases.md 4.4). The simulation's modules already build such derived tables lazily
(exploration's country type flags, intel levels, component ranges); typed arrays built at load
remove the per-state warm-up and give the injected game the same records.

### 6.5 A cache on disk

Nothing inside the regions is a pointer: entries hold string, block and entry ids, blocks hold entry
and index offsets. Only the header's region pointers are absolute. So the definitions' regions
(with 6.2 and 6.3) can be written to a file after one parse and mapped at the next start, the
interner's map rebuilt from the string table: the game's database phase and the simulation's
start then read no text (databases.md section 4, "A cache").

## 7. The options

| | a typed schema per object kind | a generic tree (the prototype) | a mix |
|---|---|---|---|
| layout | C structs per kind (`struct country { u32 capital; ... }`), lists as arrays | entries and blocks, keys as ids, the save's shape | the generic tree for everything, typed arrays for hot fields and the engine's own state |
| a read | one load | an index probe (two) and a load: 10 ns | one load on a hot column, a probe elsewhere |
| fidelity, the save written back | needs a schema of every key of every kind (the save has thousands, and the game adds some with each version) plus an overflow tree for the rest | exact for free (identical text) | exact (the tree is the save; typed arrays are derived or engine-owned) |
| the engine's code | rewritten against the schema | converted mechanically (`world.*` and the entry loops) | the generic conversion first, hot paths moved to typed columns one at a time |
| writes in parallel | fixed slots: in place | shape changes deferred for blocks others read (section 4) | as the tree, typed arrays in place |
| definitions | typed records per database | trees | trees, typed records built from them (section 6) |

The recommendation is the mix: the generic tree as the world's and the definitions' form (it is
the save, so nothing is lost and loading and writing stay trivial), the raw API for converted code,
and typed arrays for what the engine itself computes and for the few fields every phase reads
(positions, owners, sizes). The prototype shows the tree is already 2 to 6x faster than the tables;
typed columns are the next factor where a profile says so.

## 8. Workers

`sim/src/workers.rs`: N OS threads, each with its own mlua Lua state (`runtime::new_lua`: the require
paths, `RUST.clock`), `RUST.store()` returning the shared store, `RUST.worker_index` / `worker_count`,
and `engine.store.worker` loaded (the store modules only: a worker has no table world and no
definitions of its own). The main state calls `RUST.pool_run(name, arg)`: every worker runs
`worker[name](arg)` and the call returns when all have answered, with their results (text) in
worker order. That return is the barrier.

**Exploration on the pool** (`engine.store.exploration`, driven by `engine.store.bridge`):

1. the main thread prepares the inputs the store does not hold yet (below), resets the work
   counter and publishes the order (the costliest countries first, from the pass before);
2. part a (`lambda_26`): each worker takes countries from the atomic counter until none is left:
   visited systems, sensor coverage, intel levels (to a shared array), hyperlanes. A worker keeps
   its countries' results and does the same countries in parts b and c;
3. part b (`lambda_27`): the shared intel (reading other countries' intel levels from the array)
   and the surveys it gives; then the fleets' visibility records, in chunks from a second counter;
4. part c (`lambda_28`): terra incognita cleared, the fleets seen, the country's lists written
   (section 4's rules); each worker returns its countries' changes and the list changes it handed
   back;
5. the main thread applies the handed-back changes in country order.

**Determinism.** A country's results depend only on the inputs and its own state, not on which
worker computed it or when; the changes made at the barrier are made in country order. The 180-day
diff on 0, 4 and 12 workers is the same field by field.

**The inputs the main thread computes** (8 ms a day over 180 days): the game rules exploration
evaluates (`system_blocks_sensors` and `can_force_see_fleets_in_system` for 596 systems,
`has_full_sensor_range` per country: 1,250 trigger evaluations, 5 to 7 ms), the modifier values it
reads (2,504 ships, the colonies: the source holds them by id until its monthly rebuild, so they are
kept until then and published when a ship is new), the world's indexes (planet <-> colony, system and
fleet owners), and once the pixel table and the component templates. They are serial because they
are the script layer and the modifier graph, which are still Lua tables in the main state. They are
what remains between the phase and the pass.

**Defaults.** `STELLAR_WORKERS` is 4 when unset (one less than the machine's threads below 5); the
worker states are made by `runtime::new_lua`, so they have the main state's JIT limits and collector
pause.

## 9. The transition: a mirror, kept current by its writers

The rest of the engine reads and writes the Lua tables, directly in about 2,300 places (`.key.text`,
`.value.text`, entries built as `{ key = ..., value = ... }`, `type(v) == "table"`, `table.insert`
on blocks) besides 1,232 `world.field` calls, in 40,000 lines that other agents are changing. It
cannot run on the store unconverted: a cdata handle is not a table, LuaJIT's `ipairs` and `#` on a
table ignore metamethods, and identity-keyed caches break. So the table world stays the engine's,
and the store holds a mirror of what exploration reads (11 stores, the keys it reads):

- an object is built once (with its static keys: the terra incognita map, which exploration owns,
  and the galaxy's geometry);
- after the pass, the lists, maps and surveys that changed go back into the table world with
  `engine.exploration`'s own `set_list` semantics.

**The first version synced every object every day** (its dynamic keys compared with the table's in
place, its dynamic part built again where the shape changed): about 40 ms a day (fleets 13 ms, ships
8, countries 6, planets 5, systems 4), as much as the pool saved. It is still there as
`STELLAR_STORE_SYNC=all`.

**Now the writers say what they changed** (`engine/store/live.lua`): a module that changes one of the
mirrored fields marks the object (`live.touch("fleet", fid)`), and the next pass brings in only the
marked objects, the new ones (an id the mirror has not seen) and the replaced ones (an id whose
table is another). The marks are 21 lines in 8 modules (and a `require` in each), at the places the
modules write:

| module | where | marks |
|---|---|---|
| `fleets/movement.lua` | `write_state` (the movement manager written back, every tick a fleet moves), `repair` (the load's) | the fleet |
| `fleets/create.lua` | `add_owned_fleet`, `add_ship`, `enter_orbit` | the country; the fleet |
| `fleets/orders.lua` | `enter_orbit`, `leave_orbit` | the fleet |
| `fleets/stations.lua` | `add_owned_fleet`, `set_controller`, a starbase in its system, the borders in the relations | the country; the planet and both countries; the system; both countries |
| `fleets/survey.lua` | `add_surveyed` | the country |
| `construction.lua` | `add_owned_army` | the country |
| `first_contact.lua` | the finish (the relations' pre-communications names) | both countries |
| `exploration.lua` | `remove_surveyed` | the country |

**Finding the writers: the check.** With `STELLAR_STORE_CHECK=1` every unmarked object is compared
with the table world before each pass (read-only, key by key), and a stale one is counted by store
and key, then brought in. Without any marks, 60 days found `fleet.movement_manager` (2,282
object-days), `country.surveyed_deposit_holders` (15), `country.controlled_planets` and
`planet.controller` (8 each), `country.fleets_manager` (2), `country.owned_armies`, `fleet.ships`
and `galactic_object.starbases` (1 each). With the marks, 180 days found two more (`movement_manager`
twice: orbits; `relations_manager` once: borders), and after those, none. A module that starts
writing a mirrored field needs a mark; the check finds one that does not have it.

What this is and is not: the table world stays the source of truth, and the marks are the
write-through layer that keeps the store's copy current, applied at the next pass. Converting the
writers to write the store itself would have meant rewriting how movement, creation and stations
build their blocks; the marks cost a line each. The check covers what this save does in 180 days:
war, colonization, megastructures or federations changing hands would exercise writers it has not
seen, and should be run with the check once.

The sync now costs 1 to 2 ms a day (over 180 days 2.0 ms with the first day's build of 12,909
objects; 23,000 marks in 60 days and 15,000 objects brought in, most of them that first build).
Measured, with the rest, in section 10 ("The whole simulation, with the write marks").

## 10. Measurements

### Microbenchmarks (`engine/store/bench.lua`, ns per operation)

| | tables (`engine.world`) | store (`engine.store.world`) | store, raw API |
|---|---|---|---|
| a country's capital, the same object in a loop (the JIT hoists it) | 0.7 | 1.1 | 0.7 |
| the capital of every country (55 objects) | 28.6 | 22.2 | 11.3 |
| `fleet.movement_manager.coordinate.origin`, every fleet (804) | 401 | 309 | 68 |
| every top-level entry of every country (4,383), per entry | 13.8 | | 3.7 |
| each of a country's 102 keys, by name | 27.8 | 15.4 | |
| `owned_planets` of every country as numbers, per list | 127 | | 178 (into a Lua array), 23 (in place) |
| every fleet's ships' hitpoints (two stores, ids followed), per fleet | 947 | | 243 |

Before the loop-free index, the raw lookup was 130 ns (the probe loop aborted the caller's trace).
The table world's `field` goes through one global weak table indexed by object (`fields_of`): its
lookups are cache misses, and they were half the run's samples when a module called `world.field`
on many small blocks (the AI's ship building on 2026-10-13, since fixed by its owner): a store
block's index is next to its entries.

### Memory and the collector

| | Lua heap after a full collection | a full collection |
|---|---|---|
| loaded (the world and the definitions as tables) | 915 MB | 1,905 ms |
| the world's tables dropped (the world in the store) | 573 MB | 1,295 ms |
| the definitions' tables dropped too | 343 MB | 610 ms |

The store itself: 25 MB of entries and 55 MB of index for both, 2.4 MB of strings. The rest of the
heap is the script layer's (events, scripted triggers and effects as trees), the modifier graph and
the modules' caches. In the full runs the collector is 17 to 20% of the main state's samples (60
days, LuaJIT's profiler, the table below); with only exploration on the store the heap is
unchanged (the mirror is extra), so the collector's share only falls when the world and the
definitions leave the heap.

A worker state's heap is small (no world, no definitions): the same exploration pass is faster
on one worker (22 to 27 ms) than in the main state (25 to 36 ms), whose allocations pay for the
collector walking 1 GB.

### Exploration, one thread

On the loaded world, the table pass against the store's (`B.check`: both computed day after day,
nothing else running, every country compared after each):

| | engine.exploration (tables) | the store's (main state) | the store's inputs (main thread) |
|---|---|---|---|
| day 0 (the load's pass, pixel table included) | 335 to 600 ms | 47 to 126 ms | 10 to 20 ms (with the setup: 285 ms) |
| days 1 to 6 | 48 to 80 ms | 32 to 58 ms | 8 to 15 ms |

All 55 countries identical on every day (lists, terra incognita, surveys), the whole tree in the store
or the mirror. The table pass's numbers include its rule evaluations and modifier reads, which the
store's moves to the inputs.

### Exploration on N workers

Repeated passes of the loaded world (`B.scale`, the whole tree in the store; medians of 21 passes
after 5 warm-up passes, two runs; the process pinned to CCD1: 6 cores, 12 threads):

| workers | a pass (ms) | part a | part b | part c | part a's countries, summed |
|---|---|---|---|---|---|
| 0 (the main state) | 27.9 to 36.1 | 14.5 to 20.6 | 5.5 to 6.8 | 8.1 to 8.9 | 14.4 to 20.4 |
| 1 | 25.1 to 27.3 | 15.5 to 15.7 | 4.0 to 4.1 | 5.4 to 7.0 | 15.3 to 15.5 |
| 2 | 17.1 to 17.2 | 8.9 to 9.8 | 2.4 to 2.9 | 4.5 to 4.8 | 17.0 to 19.0 |
| 4 | 13.5 to 14.6 | 7.4 to 8.1 | 2.5 to 3.0 | 3.2 to 4.0 | 28.4 to 30.3 |
| 6 | 14.6 to 15.1 | 7.3 to 8.4 | 2.7 to 3.0 | 3.1 to 3.8 | 41.0 to 44.5 |
| 8 | 12.3 to 13.9 | 7.2 to 8.2 | 2.6 | 2.5 to 3.2 | 53.0 to 59.1 |
| 12 | 15.4 to 16.4 | 8.9 to 9.0 | 3.1 to 3.6 | 3.0 to 3.1 | 86.4 to 92.5 |

With 60 warm-up passes: 22.0 ms on 1 worker, 10.0 on 4, 8.3 on 8 (part a 11.4, 4.8, 3.9).

What limits it:

- **Each state's JIT warm-up.** The summed work of part a grows with the workers (15 ms on 1, 30 on
  4, 55 on 8) while the same work run whole on each worker at once (every worker doing every
  country) takes the same time on 1 to 4 workers (42 to 55 ms each). The difference is warm-up:
  every state records and compiles its own traces and side traces, and a worker meets each
  country's paths 1/N as often. After 60 passes instead of 5, part a's sum on 8 workers falls from
  55 to 28 ms. In a run of 180 days this amortizes; a shared trace cache does not exist in LuaJIT.
- **The hardware past 6 workers.** Pure reads of the store (every fleet's three-level path, 2,000
  times) take 165 ms on each of 1, 2 and 4 workers at once, and a median of 189 ms (max 261) on 6:
  the other jobs on the box share the cores, SMT siblings halve a core, and the two CCDs (6 cores
  each, 32 MB of L3 each) run at different clocks (4.7 GHz against 3.4 to 3.9 here).
- **The costliest country**: 2 ms of a 15 to 25 ms part a (16777226, then 11, 16777225): part a cannot
  go below it, about 8x. Taking the costliest first (by the pass before) keeps it from being last.
- **Serial pieces**: the inputs (8 to 15 ms a day, the script layer's rules), the barrier's merge
  (under 1 ms), the per-state duplicated caches (relations by country, 0.2 to 0.5 ms each).

### The whole simulation

The 180-day diff from the 2210.01.01 save to the headless game's 2210.07.01 (`examples/diff`):

| | fields equal | differ | draws | 180 days |
|---|---|---|---|---|
| without the store | 723,380 | 13,251 | 4,725,089 | 57.0, 69.3, 78.0 s |
| `STELLAR_STORE=ffi`, 0 workers | 723,380 | 13,251 | 4,725,089 | 57.6, 65.0, 79.0 s |
| 4 workers | 723,380 | 13,251 | 4,725,089 | 51.5, 58.2, 63.3 s |
| 12 workers | 723,380 | 13,251 | 4,725,089 | 50.7, 58.1 s |

(Separate runs on the busy box, the first figure the last run, on the final code; runs side by
side slowed each other.) Rerun after HEAD moved to e7505c3 (which changed `engine.world`'s field
index): without the store and on 4 workers, side by side, the same 723,380 / 13,251 and the same
draws, every field path equal (51.5 s and 51.9 s).

With every field path listed (`diff ... 100000`), the three runs on the store equal the run without
it on every path; the reports differ only in timings, in the statistics of trigger evaluations
(the inputs evaluate the rules for every system) and in the order of tied counts. The expected
719,675 was an earlier tree: with the working tree as it is now, other agents' changes included,
it is 723,380. Every row is the same tree.

**The first version** (the mirror synced in full every day; 2026-10-13, the collector's pause 200).
60 days (`examples/run 60`), `daily.countries_parallel` (exploration, plus the countries' timed
modifiers and ethics), two batches of the four runs; the store's part per day from its report
(the first batch); the collector's share of the main state's samples from LuaJIT's profiler (the
second batch):

| | the phase, a call | 60 days | sync | inputs | the pass (a, b, c) | merge | collector |
|---|---|---|---|---|---|---|---|
| without the store | 92.1 / 74.8 ms | 22.7 / 20.2 s | | | | | 18.8% |
| `STELLAR_STORE=ffi`, 0 workers | 98.4 / 96.4 ms | 20.5 / 20.4 s | 40 ms | 13 ms | 36 ms (22, 6, 8) | 0.7 ms | 19.8% |
| 4 workers | 75.2 / 84.2 ms | 20.5 / 20.0 s | 39 ms | 13 ms | 14 ms (8.0, 2.5, 3.3) | 0.8 ms | 18.1% |
| 8 workers | 82.5 / 76.1 ms | 18.9 / 18.5 s | 45 ms | 14 ms | 14 ms (8.2, 2.5, 3.2) | 0.7 ms | 17.2% |

On the pool the main state's samples are 13% (4 workers) and 18% (8) in C code: waiting for the
workers at the barriers. The whole day is 310 to 380 ms in these runs (the box was busy; the AI and
the monthly modifier rebuild vary most): the store's effect on it is within the noise, because the
mirror's sync (40 ms) eats what the pool saves (the pass from 36 to 14 ms, against about 60 ms for
the table pass in the same phase).

### The whole simulation, with the write marks

2026-10-14, sim-engine at 5d6afa9 (the collector's pause 400, on both sides and in the workers),
the box quiet (load 2 to 4), the process on CCD1 (6 cores, 12 threads), the store with its defaults
(4 workers), runs one after the other. The gate (`diff ... 100000`, the four runs side by side):
without the store 42.1 s, the store by default 35.5 s, `STELLAR_STORE=ffi STELLAR_WORKERS=0` 39.3 s,
4 workers 37.2 s; all four 723,380 / 13,251 with 4,725,089 draws, every field path equal.
`cargo test --release` passes.

`examples/run`, `phase_report`, ms a call (phases of 0.1 s or more):

| phase | 60 days, off | 60 days, on | 180 days, off | 180 days, on |
|---|---|---|---|---|
| `daily.countries_parallel` | 57.7 | 28.0 | 50.4 | 24.5 |
| `monthly.modifiers` | 821.6 | 1,176.2 | 1,021.3 | 837.3 |
| `monthly.budget` | 637.2 | 681.4 | 710.9 | 658.3 |
| `daily.countries_serial` | 26.2 | 24.6 | 22.7 | 27.3 |
| `ai.process` | 32.0 | 28.0 | 21.5 | 23.1 |
| `micro.update` | 2.72 | 2.31 | 1.56 | 2.12 |
| `daily.pop_groups` | 8.4 | 7.9 | 6.7 | 7.9 |
| `daily.ships_fleets_armies` | 7.7 | 7.7 | 6.2 | 7.4 |
| `daily.ai_attitudes` | 7.1 | 6.7 | 5.8 | 6.8 |
| `monthly.countries_serial` | 165.6 | 160.6 | 154.3 | 152.1 |
| `daily.colonies_parallel` | 4.1 | 4.1 | 3.7 | 4.0 |
| `daily.script_state_expiry` | 3.6 | 4.6 | 4.3 | 3.0 |
| `daily.construction_manager` | 3.0 | 2.6 | 1.9 | 2.4 |
| `daily.galaxy` | 2.5 | 2.4 | 2.3 | 2.7 |
| `monthly.colonies` | | | 22.7 | 21.2 |
| all phases | 14.1 s | 12.5 s | 36.9 s | 33.5 s |

Two more 180-day pairs: 37.8 s off against 33.8 s on (the other order), and 39.1 s against 32.7 s;
`daily.countries_parallel` 48.9 and 53.1 ms against 22.5 and 22.6. The store on 0 workers (the pass
in the main state) took 40.7 s with the phase at 49.8 ms: the pool is what makes it pay, not the
store alone.

`daily.countries_parallel` with the store, per day over 180 days (the bridge's report): the pass
11.6 ms (parts a 6.3, b 2.2, c 3.2), the inputs 8.2 ms, the sync 2.0 ms (the first day's build of
12,909 objects included), the merge 0.6 ms, ethics 1.6 ms, the timed modifier countdown under 0.1
ms. Ethics (`engine.ethics.countries_daily`: every 30 days a country's attraction) and the countdown
are too small to move to the pool; the inputs are the script layer's rules and stay serial until
the script layer reads the store.

Over 180 days the store's runs are consistently 3 to 5 ms a day slower in
`daily.countries_serial`, about 0.4 ms a tick in `micro.update`, and 1 ms in the pop groups, and
not over 60 days. The likely reason is the collector (not measured phase by phase): with the pause at 400
a full cycle over the 4 to 4.5 GB heap comes once or twice in 180 days, its steps are paid by the
phases that allocate in the main state, and with exploration's allocation moved to the workers a
larger share of each cycle falls on the phases that remain. The total is still 3.4 to 6.4 s lower
over 180 days. The heap's peak is about the same (4.5 GB against 4.0 GB: the mirror is extra, and
the world and the definitions stay in the heap), so the store has no collector effect of its own
yet, at this pause.

## 11. Assessment

**What the prototype shows.** The store works as intended where code reads it: one copy of the
world and the definitions, mapped by every thread, read at compiled speed (2 to 6x the tables on one
thread), written under the game's own discipline with one extra rule (shape changes of shared
blocks at the barrier), deterministic, and exact (the save written back as read; exploration's
results identical on 0 to 12 workers over 180 days). Exploration, the heaviest daily parallel pass,
takes about 22 ms a day on 4 workers with its serial inputs and the mirror's upkeep (11.6 ms the
pass, 8.2 the inputs, 2.0 the sync), against 47 to 56 ms for its table version, and the 180 days
3.4 to 6.4 s less. The mirror, kept current by 21 marks in its writers, costs 2 ms a day instead of
40; the inputs (the script layer's rules) are now the larger serial part.

**What moving the whole engine takes.**

1. The world API's callers converted: `type(v) == "table"` to `W.is_block(v)`, entry loops
   (`for _, e in ipairs(b) do if e.op and e.key.text == k`) to the raw API, entries built as tables
   (`{ key = { text = k }, op = "=", value = v }`) to `S.append` / `S.append_block`, `.text = x` to
   `S.set_value`, `table.insert` / `table.remove` on blocks to `S.insert_at` / `S.remove_at`. About
   2,300 sites and 1,232 `world.field` calls in 47 files: mechanical, file by file, each checked
   by the 180-day diff, but best done by each module's owner (they are being edited now). The
   script layer (`simscript/eval.lua`, `engine/interface.lua`) is the largest reader and the most
   valuable: once it reads the store, the rules and triggers can run in workers too.
2. The definitions consumed from the store (the script layer's trees: events, scripted triggers and
   effects, script values), so workers can evaluate script. Then the inputs stop being serial.
3. The modifier graph (`lua/stellar/graph`) in typed arrays: its node values are the most read
   derived state (every phase), and its monthly rebuild (1.5 s a call) is one of the parallel
   phases.
4. Per phase, the game's split: the per-object part on the pool, the serial part on the main
   thread, typed arrays for what one part computes for another (section 5).
5. Shape changes of shared blocks at the barrier (section 4), applied in object order.

**What to expect.** Single-threaded, an engine on the store should be 1.5 to 2.5x faster than today
on its reading (the microbenchmarks; less where the work is computation, not lookups), and the
collector's share should fall from 11 to 14% to a few percent (the heap from 1 GB to the script
layer's 0.3 GB, then less as the script trees move too). In parallel, a phase made of per-object
work scales to about 4x on 4 workers and 5 to 7x on 8 on a quiet machine, bounded by its costliest
object and by the per-state JIT warm-up; the phases with fine-grained objects (pop groups, colonies,
fleets) balance better than countries. With 60% of the time in such phases, the day would go from
270 ms to something like 270 x (0.4 + 0.6 / 5) / 2 = 70 ms on 8 workers: within 3x of the game, the
rest being the serial phases (the AI's commands, events) and the script layer's speed itself.

**What was not done** (the open items):

- the colonies', pop groups' and modifier phases on the pool (the same pattern; they need the
  script layer's triggers in workers, item 2 above);
- the whole engine on the store (item 1);
- for the in-game database builder (databases.md section 4): the definitions in the game's order
  with every duplicate kept and a per-folder index array (6.2), and the locations, a line per entry
  and `{ file, first, last }` per block (6.3). Both are designed here and not built: `store/defs.lua`
  still keeps the last definition per name, sorted, and no lines;
- the schema layer's typed records (6.4) and the cache on disk (6.5);
- a quiet machine for the scaling numbers.

## 12. The engine on the workers

The mirror above holds what exploration reads. To run the engine's own modules on the workers
(AI, pops, colonies, ...), each worker gets **the engine itself over a copy of the whole world**:

**The copy** (`store/full.lua`). `S.build(world.tree)` puts the whole table world in the store
(1.08 M entries, 0.6 s), every table block mapped to its store block. The table world stays the
source of truth, and the copy is brought up to date at each sync from marks the writers leave:

- `engine.world`'s writers (`set`, `child`, `append`, `insert`, `append_value`, `remove_value`,
  `remove_entry`, `reindex`, `create`, `remove`, and the new `push` and `adopt`) report the block
  they changed. After `world.track_owners()` every block knows its object and the block it is in.
- Modules that change a block themselves (an entry's text set directly, `table.insert`) call
  `world.wrote(block)`: the countdowns in `systems.lua`, research, exploration's lists, the AI's
  plans and the economy orders, construction's zones, traditions, ship names and fleet templates.
  `world.push(block, value)` replaces direct appends of new blocks, so they get an owner.
- A marked block is written again **in place**. It keeps its block id, and so does every block in it
  whose table is still there; only tables new to the copy are built. Handles and caches keyed by
  block id in the workers stay valid across syncs. `S.rebuild_index` reuses the block's index.
- `STELLAR_STORE_CHECK=1` compares every object with the table world each day and reports stale
  keys by path. Over 180 days from `autosave_2210.01.01` it reports **0 stale keys**, from 43 kinds
  when only exploration's writers marked.
- Cost: about 9 ms a simulated day over 180 days (blocks 5.6, objects 3.6). The copy builds about
  620 new blocks a day for tables the table world makes anew, and never frees the old ones yet.

**A worker's engine** (`store/worker.lua`, job `engine`). `engine.store.world` is attached to the
copy and bound as `engine.world`, then `require("engine")`, `host.init` and `defs.load` as the main
state does (3.9 s, 437 MB of Lua heap per worker). A worker never writes the copy: the world's
writers raise an error there, as do `RUST.rand`, `RUST.skip` and `RUST.effect` (a parallel phase may
not draw or send engine effects). The engine's modules test world values with `type(v) == "table"`;
in a worker the global `type` says "table" for a block handle, so the existing code takes the same
branch, and code that then walks a handle as a Lua table (`ipairs`, `#`, `.text`) fails loudly and
is moved to the API. Two functions are new in both worlds for that: `world.count(block)` and
`world.key(block)` (a cache key: the table, or the block id).

**Parity.** A probe compares a worker's answers with the main state's: the attitude weights of all
178 AI relations of the 2210 save, opinion term by term. They are equal on day 1 and on day 30.

**A phase on the workers** (`store/parallel.lua`). `STELLAR_PARALLEL=<phases>` (or `all`) names the
phases that run there; none by default. `parallel.run(job, arg)` syncs the copy, gives the workers
the date and runs the job; the workers only read, and return their decisions as text, which this
state applies in the game's order. The first is the daily attitude update
(`CCountryAI::UpdateAttitudesThreaded`, parallel in the game): each worker takes every Nth due
country (`attitudes.part_text`), and the changes are merged back in country order. The 180-day gate
is identical with it on and off (723,380 / 13,251, the same 4,725,089 draws, the same 432 updates
and 1,260 relations). It is not faster: the phase is about 5 ms a day, less than the copy's sync
and the workers' slower reads (handles allocated per read, blocks scanned where they have no
index). The large parallel phases are next: the AI's decisions (`UpdateAIParallel`), pops and
colonies, the monthly strategy.

## Files and switches

| | |
|---|---|
| `sim/src/store.rs` | the store's regions, the atomic reservations, the interner; `RUST.store()`, `RUST.store_usage()`, `RUST.pool_start(n)`, `RUST.pool_run(fn, arg)`, `RUST.pool_stop()` |
| `sim/src/workers.rs` | the pool: N threads, a Lua state each with `engine.store.worker` |
| `sim/lua/engine/store/core.lua` | the records (`ffi.cdef`), strings, allocation, the key index, reads, writes, build from a tree, write to text |
| `store/world.lua` | `engine.world`'s API over the store |
| `store/arrays.lua`, `store/objects.lua` | typed arrays, id maps, object tables |
| `store/defs.lua` | the definitions in the store |
| `store/exploration.lua` | exploration over the store, in three parts |
| `store/bridge.lua` | the main thread's side: the mirror, the inputs, the pass on the pool, the merge; `B.check(days, workers, mirror)`, `B.scale(counts, reps, warm)`, `B.read_scale(...)` |
| `store/worker.lua` | a worker's jobs (`part`, and benchmarks) |
| `store/live.lua` | the write marks: `live.touch(store, id)`, called by the modules that write what the mirror holds (section 9) |
| `store/bench.lua` | the round trip, the microbenchmarks, the heap |
| `STELLAR_STORE=off` | exploration's own pass on the table world (the store is on by default; `ffi` is the same as unset) |
| `STELLAR_WORKERS=N` | the pool (0: the pass in the main state; unset: 4, or one less than the machine's threads below 5) |
| `STELLAR_STORE_CHECK=1` | every unmarked mirrored object compared with the table world before each pass; the stale ones counted by store and key (in the bridge's report) and brought in |
| `STELLAR_STORE_SYNC=all` | every mirrored object brought in every day (the first version) |
| `STELLAR_STORE_DEFS=all` | every folder of definitions in the store (by default only the six exploration reads) |
| `STELLAR_STORE_SCALE=f` | the regions' capacities times f (default 1; 0.25 on Windows, which commits a large allocation at once) |
| `STELLAR_STORE_PROF=1` | the parts' functions timed, per state |

Scripts used for the numbers (on hippo's share, `tmp_sim/`): `store_bench.lua`, `store_check.lua`,
`store_scale.lua`, `store_read_scale.lua`, `store_defs.lua`, `store_gate.sh`, `store_days.sh`, run as
`STELLAR_LUA=<script> examples/run 0 <save>`; for the write marks `store_gate2.sh` (the strict gate),
`store_final2.sh` (gate, tests, timings), `phase_parts.lua` / `phase_parts_report.lua` (the phase's
parts), `jit_events.lua` (trace events).
