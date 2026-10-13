# A standing dependency graph for modifiers and the economy (Lua)

The design of `lua/stellar/graph/`: the Lua replacement of the game's modifier and economy
computations as one standing graph of cached numbers, with lazy chunked invalidation and a
per-frame schedule driven by deadlines. What the game does is in [modifiers.md](modifiers.md).
It runs offline (LuaJIT, no game): `tools/graph_test.lua`, `tools/graph_bench.lua`,
`tools/graph_mapping.lua`, `tools/graph_nodes.lua`. In the game it runs beside the node system, in
shadow mode (below); nothing of the game's is replaced yet.

## Why

The game keeps one modifier set per object and rebuilds it whole whenever anything above it
changes: a technology on a country invalidates the country's node, every fleet's, every ship's,
every planet's, colony's and pop group's below it (filtered only by broad category masks), and
each rebuild re-adds every source, copies the parent's whole set and clones the parents for the
tooltip breakdown. The economy has no cache at all: every production, upkeep or cost is
recomputed from the resource tables with a linear search per modifier lookup, up the category
chain, monthly for the budget and again every frame for the planet view, its tooltips and the
fleet and outliner buttons (ship design upkeep for every candidate design). Late modded games
(10,000 ships) spend their frames there.

Most of that work is recomputing values that did not change. The values are sums and products:
mathematical formulas over a small number of inputs each. Kept as a graph of cached numbers, a
change costs what it actually changes, and the remaining work can be ordered and spread by when
it is needed.

## Model

- **A node is a number.** An input (a local modifier sum, a job's base output, a scale such as
  workforce / 100, a trigger result) or a formula over other nodes: `sum` (base + sum of coef *
  x), `clamp` (a sum clamped), `product`, `min`, `max`, or `func` (any Lua function of its inputs,
  the escape hatch).
- **An edge is a dependency**, with a coefficient (a link's scale, a count of units).
- **Granularity: one node per (object, modifier type)** that is used, not one modifier set per
  object. A change of `ship_fire_rate_mult` on a country marks the fire-rate nodes below it and
  nothing else.
- **Every value is cached**; a clean read is a flag check and an array load.
- **Values are made on demand**: a (holder, type) node exists once something reads it, with the
  nodes it reads. The graph holds what the game and the UI actually use.

## The engine: `stellar.graph.core`

### Storage

Structure of arrays in malloc'd memory (`stellar.graph.buffer`, grown with realloc, outside the
Lua heap): per node an op, flags, a declared class and an effective need, a level, the cached
value, the base, a running sum and pending delta (sums), clamp bounds, and the offsets and counts
of its input and dependent blocks (85 bytes). Edges live in two pools: an input slot (source,
coefficient, index of the matching dependent slot) of 16 bytes and a dependent slot (node, index
of the matching input slot) of 8 bytes. Each node's inputs and dependents are contiguous blocks
(power-of-two sizes, recycled through free lists); the back-pointers make removing an edge O(1)
once found (a swap with the last slot, fixing one back-pointer), and finding it scans the shorter
of the two lists. Ids are reused.

### Invalidation: lazy and chunked

1. `set(input, x)` is O(1): it records the input in the frontier. Several sets coalesce.
2. `mark(budget)` processes the frontier in chunks: an input gives its change to its direct
   dependents (a delta for sums), and everything downstream is marked dirty, once: marking stops
   at nodes already dirty, so a dirty region that is never read is never walked again. Structural
   changes (link, unlink, coefficients, bases) give their delta and mark the same way.
3. A dirty node goes into a bucket by (need class, level). At the end of a tick (`after_tick`
   finishes marking) the buckets are the list of pending invalidations: `g:pending()` (counts by
   class) and `g:each_pending(class, f)` (every node, in the order it will be computed).
4. `run(class, budget)` computes up to `budget` dirty nodes needed by `class` (or more urgent),
   lowest level first, so that a node is always computed after its inputs. Marking is pessimistic,
   computing is exact:
   - a node none of whose inputs actually changed is only unmarked (early cutoff);
   - a sum (or clamp) whose inputs changed applies its accumulated delta: O(1) whatever its number
     of inputs (a country total over thousands of units), with a full recompute every 64 deltas
     against rounding drift, and on structural changes;
   - other ops recompute from their inputs;
   - a value that did not change does not propagate (optionally within an epsilon).
5. `get(node)` is always exact: it finishes marking if needed, then computes the dirty part of the
   node's inputs (and only that), in level order. A read never waits for the schedule.

Invariants, checked by `g:check()` in the tests: back-pointers, levels (every input lower than
its reader), needs (every input at least as urgent as its readers), marking (after marking, every
dependent of a dirty node is dirty), and every clean node's cached value equals its formula.

### Order: incremental levels

Each node has a level, higher than all its inputs'. Linking `u -> v` with `level(u) >= level(v)`
raises `v` and, as needed, its dependents (refusing the link if this reaches `u`: a cycle).
Levels never go down, which keeps them a valid order. A dirty node whose level rose is queued
again; stale bucket entries are skipped. Computation can therefore be reordered freely within a
level and across classes, and the graph can change between any two chunks.

### Deadlines: need classes

A node has a declared class and an effective need, the most urgent of its own class and its
readers' needs, kept up to date when classes and edges change (lowered at once along the inputs,
raised again by recomputing from the readers). Classes, most urgent first:

| class | due | typical nodes |
|---|---|---|
| FRAME | before the frame is drawn | an open tooltip, the planet view, the outliner's visible entries |
| TICK | before the next tick | values the simulation reads every tick (combat, movement) |
| DAY | before the tick that ends the day | daily updates (deficits, upgrades, pop growth inputs) |
| MONTH | before the tick that ends the month | the budget, colony snapshots |
| READ | only when read | everything else |

## Scheduling: `stellar.graph.schedule`

The scheduler knows the expected frame rate and tick rate (given, or measured: `measure = true`
follows the real ones), and where the game is in its day (10 ticks) and month (30 days). Per
frame (`s:frame()`):

1. finish marking (in chunks; if the frame's budget runs out first, compute waits for the next
   frame, reads still being exact);
2. compute all FRAME work;
3. for TICK, DAY and MONTH: the pending count over the frames left before the deadline
   (`frames = time to the deadline * fps`): each frame does its share, so a month's work is spread
   over the month's frames and a tick's over the frames before the tick;
4. work ahead with the rest of the frame's budget (seconds, 2 ms by default), most urgent first.

Paused, ticks never come: only FRAME work and work-ahead run. `s:before_tick()` is the barrier
(the hook on `CGameState::HandleTurnTick`): what is due at this tick and not done is done there,
and counted as missed. `s:after_tick()` is the end of the tick: it finishes marking (so the
pending list is complete) and advances the date. Work is counted in nodes; the scheduler checks
the clock between chunks and keeps a running cost per node (`s:plan()` shows the quotas).

## Mapping the game

### Modifiers: `stellar.graph.modifiers`

- **Definitions** from `modifiers.log` (`defs:read_log`), or later from `_Definitions` in memory:
  names, ids and the game's `ModifierCategory` masks (the label values are in the module).
- **Holders**: one per object that has a modifier node in the game (country, planet, colony, pop
  group, fleet, ship, leader, starbase, ...). A holder has sources (static modifiers, timed
  modifiers, traits, edicts, components: `tree:add(holder, name, { type = value })`) summed per
  type, and links to the holders it reads (`tree:link(child, parent, scale, mask)`), as the game's
  `AddModifierNode(parent, scale, category mask)`.
- **Values**: `value(H, T) = local(H, T) + sum over parents of scale * value(P, T)` when T's
  categories meet the link's mask; one sum node per (holder, type), made when first read, with its
  parents' nodes. Moving a ship to another fleet relinks its materialized types; replacing a source
  is a delta on its types.
- The game's 34 node categories map to holders and links: the declared dependencies of each node
  type (modifiers.md, the table of node categories) are the links (a ship reads its fleet and the
  starbase nodes; a fleet its country, system, leader, starbase; a planet its country, sector,
  system, starbase; a colony its planet; a pop group its colony).

### Economy: `stellar.graph.economy`

- **Categories** from `common/economic_categories` (pdxscript): parents, generated add and mult
  modifiers, triggered modifiers, with the game's naming rules (`cats:generated`; all 7,758 names
  they make for vanilla are in `modifiers.log`).
- **One resource table entry** (category C, table N, resource r, read on holder H with scale s):
  `s * (base + A) * factor` with `A = value(H, C_r_N_add)` (own category only) and
  `factor = clamp(1 + sum over C's chain of value(H, a_N_mult) + value(H, a_r_N_mult), 0.1, inf)`
  (MIN_ECONOMIC_MODIFIER_MULT = -0.9). The factor is one clamp node per (holder, C, N, r), shared
  by every unit of that category on the holder: thirty miners on a colony share one factor.
- **Triggers** (triggered blocks of a resource table, triggered category modifiers) are input
  nodes (1 or 0) set by the script layer, so a resource table never evaluates script.
- **Units**: `eco:unit(holder, { category, produces = blocks, upkeep = blocks, ... }, scale)` makes
  the entries; the scale (workforce / 100, size / 100, a count) is an input. Totals (a colony's
  produces, a country's income by category, fleet upkeep) are sums with the units' counts as
  coefficients, of class MONTH for the budget and FRAME while the UI shows them.

### Script effects and engine effects

The graph is state the script layer owns. Its inputs come from two sides:

- **script effects** run in Lua (an `add_modifier` executed by the Lua script engine, a trigger
  result the Lua evaluator computed) change graph inputs directly and are consistent at once;
- **engine events** (a ship built or moved, a building finished, a technology researched, a job
  assignment) are observed from the engine (hooks on the functions listed under Invalidation in
  modifiers.md, or a diff of engine state at the tick barrier) and become input changes at the
  tick point, in a deterministic order.

Its outputs: the UI can be served directly from cached values (hooked tooltip and view
functions return graph values: no barrier, they only read). Values the engine itself must use
(replacing node rebuilds, the monthly budget, the stockpile) are engine effects: they go through
the queued Lua -> engine barrier at the tick point, never written from a frame.

### Numbers: fixed point

The game computes in `CFixedPoint` (int64, 1.0 = 100000), with a rounding per scaled entry. The
graph computes in doubles: sums of fixed-point values are exact in doubles below 2^53 (about 9e10
in game units), so storing raw fixed-point integers keeps sums exact; products and scaled
additions need the game's rounding to match to the last digit. Parity is a shadow-mode question
(compare with the game's values) before anything is switched over.

## The game's nodes, all of them: `stellar.graph.nodes`

The modifier surface is small: in a 2210 game, 15,700-16,000 registered nodes, of which about 5,800
hold values (110,000-117,000 values), built from about 13,000 parts. So the graph does not serve
hot spots next to the node system: it holds every node.

- A game node is a holder (kind = its `EModifierNodeCategory`, key = its registry index).
- Its parts (`_Added`) are of two kinds. A parent node's part is a clone of the parent's whole value
  set (`AddModifierNode`), with the call's multiplier and the filter `_Categories & mask`: a link,
  `tree:link_fixed(child, parent, mult, filter)`, which truncates each entry as
  `CModifier::AddModifierEntry` does. Every other part is one of the node's own sources (static,
  timed and triggered modifiers, traits, technologies, a ship's component set, colony
  contributions): `tree:add`, folded with its multiplier and filter.
- The parents are the nodes whose `_ChildNodes` hold the node (read by `stellar.modifier_capture`).
  The part that is each one's clone is found by content. A parent that added nothing has no part.
  Its link takes the filter of its kind as seen on other parts, or, for a kind never seen with a
  part, the child's own `_Categories`. In the 2210 capture, 17 of the 22 kinds that have parts use
  exactly that filter, i.e. their call passes no mask. The five with a mask of their own:
  Fleet < Sector, Planet < Country (two masks), PopGroup < Country (Habitability),
  Ship < StarbaseDefensePlatform, Starbase < Sector.
- `_ChildNodes` keeps stale edges. The game drops a child only when that parent invalidates it, so a
  child invalidated otherwise (a ship moved to another fleet) stays listed. A parent with no part
  whose values would pass the link's filter is such an edge, and it is left out.
- The real structure is much denser than the parts show: 32,798 edges, 5,893 of them with a part.
  Every planet reads its system's GalacticObjectLeader, -CosmicStorm and -PsionicAura nodes, and
  every fleet its system's nodes, which are empty in this game. A capture without children (the
  first one) finds parents by content, among the categories each category declares it reads
  (`nodes.READS`). That gives the right values but guesses wrong edges: fleets "read" planets whose
  values equal their sector's.

`tools/graph_nodes.lua <capture> <modifiers.log>` builds the tree from a capture, materializes
every value the game holds and compares each with the game's, exactly:

| capture | nodes | values | exact | graph |
|---|---|---|---|---|
| `modifier-nodes-2210.tsv` (no children) | 15,678 | 109,934 | all | 117,619 nodes, 142,373 edges |
| `modifier-nodes-2210-midload-edges.tsv` (the game's edges) | 15,953 | 116,898 | all | 234,078 nodes, 483,946 edges |

A clean read of every value takes 120-270 ns a value (through the type name). One type changed on a
country marks 38-43 nodes in the graph; the game rebuilds the 81-102 nodes below it whole
(1,950-2,170 values). Graph invariants hold, and after the changes and their undo every node is
exact again.

### Shadow mode

`modifier_graph.txt` next to the DLL: `shadow` (`stellar.modifier_shadow`; it hooks what
`modifier_stats.txt` hooks, so only one of the two runs). `src/dll/modifier_shadow.cpp` records the
id of every node `CModifierNodeBase::Update` rebuilds, from any thread. After each
`CModifierNodeManager::Update` pass it hands them to Lua on the thread that ran the pass, never
waiting: while Lua is busy, they wait for the next pass. At the first tick of a game the mirror is
built from every node and checked whole, and the snapshot is written to
`logs/stellarstellaris-modifier-nodes-shadow.tsv`. After each pass:

1. the recomputed nodes are read again, with their parents;
2. `mirror:assign` gives each to the mirror. A node whose own parts changed is a root of the
   change. The others the game recomputed only because something above them changed, and the
   graph must arrive at their values by itself;
3. the graph's values are compared with the game's for every recomputed node, every node the graph
   marked that the game did not recompute, and a window of 400 other nodes in turn.

The counts (passes, recomputed nodes, roots, relinks, the graph's marks and computes, mismatches
by category) are logged every game month, and the first 60 mismatches as they are found.

Status: built and installed in the game. It has not run over game time yet: the one load so far
ran the machine out of commit memory (a `std::bad_alloc` in the game's `CBordersGraphics` on the
first frame after the load, with 17 of 24.9 GB committed before the game started), with a capture
running in the middle of the load. The `-continuelastsave` argument needs the launcher, and `quick=<save>`
(RunGame -> `CFrontEndIdler::LaunchSave`) did not load the save either, so the save is loaded by
hand.

## Status

Implemented and tested offline:

| module | |
|---|---|
| `stellar.graph.buffer` | malloc'd growable typed arrays |
| `stellar.graph.core` | nodes, ops, edges with back-pointers, levels, needs, frontier and buckets, delta sums, early cutoff, pull reads, invariant checker |
| `stellar.graph.schedule` | frame / tick / day / month deadlines, quotas, work-ahead, barrier, end-of-tick report |
| `stellar.graph.modifiers` | definitions (modifiers.log, ModifierCategory), holders, sources, links with scale and mask, values on demand |
| `stellar.graph.economy` | categories (pdxscript), generated names, the game's entry formula, triggers as inputs, units and totals |
| `stellar.graph.nodes` | the game's whole node tree: captures read and written, holders, links with the game's fixed-point truncation, own sources, a node given again after a pass (`mirror:assign`), exact comparison |
| `stellar.modifier_shadow` | the mirror beside the game's node system, checked after every pass (built, not yet run over game time) |

`tools/graph_test.lua`: 19 tests (formulas, laziness, cutoff, delta drift, edges, cycles, needs,
budgeted level order, the pending list, a randomized test of graph changes against a naive
evaluation with every invariant checked, the modifier tree, fixed-point links, the node tree from a
capture with and without children, passes given to the mirror, the economy formula, the
scheduler). All pass for every seed tried.

`tools/graph_mapping.lua` on vanilla 4.5.2: 45,583 definitions, 26 resources, 270 economic
categories (deepest chain 8), 7,758 generated names all found in `modifiers.log`, 3,095 static
modifiers (5,975 entries), 264 jobs with resources (668 blocks, 361 with a trigger); a colony with
one bulk unit of each of 260 jobs is 3,912 nodes and 6,632 edges; a country-wide
`planet_jobs_produces_mult` edict marks 1,357 nodes, and reading 14 totals computes 272 of them.

`tools/graph_bench.lua` (synthetic late game, 50 countries, 1,000 fleets, 10,000 ships, 2,000
planets, 20 types read per ship; LuaJIT 2.1 on the dev machine, sharing it with a running game, so
times vary by about 3x between runs):

| | |
|---|---|
| graph | 221,000 nodes, 220,000 edges; 33 MB arrays, 42 MB Lua (holders) |
| first read of everything (builds the nodes) | 280-380 ms |
| clean tooltip read | 7-22 ns per value (200,000 values: 1.3-4.3 ms) |
| a country edict on one type | add 0.03 ms, mark 0.3-0.4 ms (221 nodes), recomputed when read |
| the game's way, same change | 221 modifier sets rebuilt, 14,305 entries added |
| every country changes 5 types | 2,431 nodes: mark 0.4 ms, compute 2.4-3.2 ms (all by delta) |
| simulated session, 200 ticks, 1,200 frames, a 200-ship tooltip open (4,000 values read per frame) | graph work 0.008-0.012 ms per frame on average, 0.18-0.42 ms at most, nothing left for the barrier |

At 50,000 ships (1.1 million nodes and edges): clean reads 12.6 ns, every country changing 5
types marks 13,212 nodes in 3.1 ms and computes them in 15.7 ms; 234 MB of arrays and 182 MB of
Lua, which is the first thing to reduce.

## Next

1. **Memory**: per-node clamp bounds and capacities in side tables or smaller types (85 -> about 50
   bytes), holders as flat arrays instead of Lua tables, sources stored once per static modifier
   (a ship's components are shared by its design), types shared by all ships of a design.
2. **Read the game's data in memory**: `_Definitions` and the node tree are read
   (`stellar.modifier_capture`); the economic categories are next.
3. **Shadow mode over game time** (built): months of a game, mismatches by category; then
   `ApplyModifiersToTable<N>` the same way.
4. **Replace the node system**: the manager's passes and `InvalidateChildren` off. A node marked
   invalid is rebuilt by its own `CalculateModifier` with `AddModifierNode` reduced to recording
   the edge, so only its own parts are computed. The graph propagates, and Lua writes the values
   that changed into the nodes' `CModifier`s, which the game keeps reading as before. Then the own
   sources move from `CalculateModifier` to Lua category by category (the save-source attribution
   of `sim/lua/simscript/modcheck.lua` is the start for countries).
5. **The economy and the views**: the planet view and its tooltips, `GetLatestShipDesign` (design
   upkeep per candidate design, per country: a handful of cached nodes), fleet and ship tooltips;
   the tooltip breakdown read from the graph's edges instead of cloned parents.
6. **The monthly budget** as an engine effect through the barrier.
