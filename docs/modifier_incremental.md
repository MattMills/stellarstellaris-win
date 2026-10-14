# The incremental modifier graph (sim/)

Every system of the simulation reads its modifier values from the rewrite's own graph, built from
the world (`engine.economy.world_source`, `engine.modifiers.world`). Until now the monthly modifier
phase threw that graph away and built it again, twice: once without the parts whose multiplier is
another modifier's value, then with them, read from the first. Now the graph is kept from month to
month and only what changed is changed (`sim/lua/engine/modifiers/incremental.lua`). Every value is
the same as the whole build's, checked every month with `STELLAR_MODIFIER_CHECK=1`.

Everything here was measured on 10.5.0.24 (Ryzen 9 5900X, 12 cores) from the 2210.01.01 autosave.
The box was shared with other agents' runs, so single timings carry 10 to 30% of noise. The
"before" timings were taken on the same tree, 7d2f1a5, alternating with the "after" runs.

## In short

- **Before**: about 0.8 to 1.3 s a monthly rebuild. Most of it computed the parts of all
  ~15,700 holders twice and built two graphs. Each rebuild also emptied the cache of
  `source.get`, so the budget phase then recomputed about 4,000 values tables (370 ms).
- **What changes in a month**: very little. The parts of 24 to 45 holders out of 15,700 change.
- **After**: each holder's parts are computed once and compared with last month's. Only the
  differences reach the graph, one type at a time. The second build is now only for the 220
  holders whose parts read another modifier's value, and its triggers are not evaluated again.
  Only the cached values of the holders whose values changed are dropped.
- **Results**: the monthly update takes 230 to 290 ms in the check runs (pass 1 is 160 to 190 ms
  of that). The budget phase computes about 470 values tables (22 ms) instead of about 4,000.
  Over 180 days, `monthly.modifiers` drops from about 985 to about 320 ms a call (collector
  included), `monthly.budget` from about 570 to about 425 ms, and the phase total from 32.4 / 32.7 s
  to 28.0 / 30.3 s. Allocation drops from 213 to 52 MB a month. See [Timings](#4-timings).
- **Correctness**: over 180 days, 7 updates were compared with a whole build: 109,881 holders and
  771,561 values, with 0 differ, 0 missing and 0 extra. The 21,892 values tables still cached at
  those points also showed 0 differences. The 180-day diff is unchanged (723,380 equal / 13,251
  differ, 4,725,089 draws), and `cargo test --release` passes.

## 1. The rebuild before

The flow was:

1. `P["monthly.modifiers"]` (`systems.lua`) called `source.rebuild()`, which called
   `mw.world_graph()`.
2. `world_graph()` made a new `engine.modifiers` source and a new structure.
3. It then called `M.build(core.new(), ...)` twice. The first build left out parts with
   `mult = modifier:x`. Between the builds, `src.resolve_ref` was set to read the first graph.
4. Afterwards the source cache was emptied and `economy.invalidate()` was called.

Split measured at 5d6afa9 (the rebuild code is the same at 7d2f1a5). The figures are from 60 days
with the profiler on (`tmp_sim/inc_measure.lua`), 882 ms a rebuild:

| part | ms a rebuild |
|---|---|
| `structure.new` | 10 |
| `modifiers.new` (the world indexed) | 24 |
| build 1: parts (of which triggers) | 416 (133) |
| build 1: the graph (holders, links, folds, `tree:add`) | 89 |
| build 2: parts (of which triggers) | 266 (123) |
| build 2: the graph | 82 |
| collector, inside the rebuild | no samples in the GC state; 213 MB allocated per rebuild (collector stopped) |
| after it: `mw.values` for `source.get`'s misses | 5,454 calls a month, 425 ms |

The collector was not paid inside the rebuild. It was paid in the phases after it: the rebuild left
213 MB of garbage every month.

Pass 1 cost more than pass 2 because a fresh source parses its definitions again: the component
and section templates, definition blocks and inline scripts. Ships took 112 ms in pass 1 against
32 ms in pass 2, and countries 75 against 38.

Parts time by category, in ms a rebuild (pass 1 / pass 2):

| category | ms (pass 1 / pass 2) | holders | read another value |
|---|---|---|---|
| Planet | 131 / 109 | 6,080 | 35 |
| Ship | 112 / 33 | 2,512 | 0 |
| PopGroup | 65 / 58 | 158 | 134 |
| Country | 75 / 38 | 55 | 2 |
| Leader | 12 / 6 | 403 | 0 |
| Colony | 5 / 11 | 49 | 49 |
| Fleet | 5 / 4 | 811 | 0 |
| others | under 5 each | | 0 |

**What changes from one month to the next.** Each holder's parts (name, multiplier, filter, sorted
values) were recorded per build and compared with the build before (`INC_CHANGES=1`, 120 days, 4
months):

| | month 1 | month 2 | month 3 | month 4 |
|---|---|---|---|---|
| holders with parts (of 15,664 to 15,744 in all) | 12,295 | 12,292 | 12,322 | 12,326 |
| holders whose pass-1 parts changed | 24 | 33 | 33 | 26 |
| parts that differ (of ~12,930) | 105 | 144 | 143 | 120 |
| holders added / removed | 8 / 0 | 22 / 25 | 30 / 0 | 4 / 0 |
| holders whose parents changed | 14 | 20 | 34 | 8 |
| holders that read another modifier's value | 220 | 220 | 220 | 220 |
| holders whose pass-2 parts differ from pass 1 | 7 | 9 | 8 | 7 |

The differing parts are:

- the colonies' status parts (70 to 102): stability, amenities, housing and employment move every
  month;
- 4 pop groups' shares of their colony's buildings and jobs (40 parts);
- the skill statics of leaders who leveled (governors, councilors, rulers);
- a few districts, zones, jobs and buildings;
- the star of a fleet that moved;
- a timed modifier;
- one technology.

No ship's own parts changed in 4 months.

## 2. The design

`engine.modifiers.incremental` keeps:

- **a record per holder**: its parts and their sums by type, its links, and its holders in the two
  graphs;
- **G2**, the graph that is read (`stellar.graph.core` under a `stellar.graph.modifiers` tree);
- **G1**, the graph of the pass-1 parts (the old first build). It is made only for the holders
  whose values are read during pass 2, and their parents: 624 holders instead of 15,700;
- **the `engine.modifiers` source**, kept from month to month. `src:refresh(st)` indexes the world
  again and drops what was computed from it. That is the pop groups' shares, the new-colony counts
  and the structure. What was read from the files stays cached.

An update (`wg:update()`) runs these steps:

1. **Records and links.** It makes `structure.new` and walks `st:nodes()`, finding records by
   category and owner. It creates new records, takes out the ones that are gone (destroying their
   G1 holders), and compares `st:parents` with each record's links.
2. **Pass 1.** It computes every holder's parts with `src.resolve_ref` unset and compares them with
   the record's. The test is the same multiplier, filter and values in order. A part's values are
   usually the source's cached table of a definition, so the comparison is mostly identity checks.
   Where they differ, it sums the parts by type id with `modifiers.fold`, as the build does. Every
   read of `src.resolve_ref` goes through `ref_of(self)`, which sets `src.ref_used`. A holder whose
   pass 1 read it is a **reading** holder. These are the `mult = modifier:x` blocks, the job output
   multipliers (`value:job_total_output_modifier`), and a colony's stability and amenities.
3. **G1** is brought up to date for the records it has: links and sums.
4. **Pass 2** recomputes only the reading holders' parts, with `src.resolve_ref` reading G1.
   - `h1_of` makes a G1 holder, with its parents, the first time it is read.
   - Every other holder's pass-2 parts are its pass-1 parts. Nothing else in a holder's parts reads
     `resolve_ref`, and the code is the same otherwise, so this matches the whole build exactly.
   - The pass-1 parts are not enough to tell whether a reading holder changed. Its pass 2 reads more
     of the world than pass 1 does (a colony's stability reads its pop groups' happiness and power),
     so reading holders are always computed again.
5. **G2 is changed only now.** Gone holders are destroyed, new ones made, links redone where they
   differ, and each holder's own values changed by the difference of its sums. Until this step, G2
   and its types memo are exactly last month's.
   - This matters because a trigger can read a modifier: `check_modifier_value` and `modifier:x`
     in a value go through `E.modifier` → `source.get`. In the whole rebuild such a read during the
     rebuild saw the previous graph; here it sees the same.
   - A values table it computes then is last month's, and step 6 drops it if it changed.
6. **What changed** is collected in two ways:
   - **Types may have changed** below every holder whose set of nonzero own types changed, whose
     links changed, or which is new. The walk goes down `h.children`. Those holders' memoized types
     (for `mw.values`) and cached values are dropped.
   - **Values changed**: the dirty nodes (`g:each_pending`) are listed with their cached values,
     the graph is computed (`g:flush`), and a holder is changed if any of its nodes now differs.
     Flushing also keeps the core's dirty buckets from growing: nothing else runs `g:run` on this
     graph.

**One source per type.** `stellar.graph.modifiers` keeps a holder's own value of a type as the sum
of its sources. Each type is its own source (`tree:add(h, id, { [id] = v })`). A change replaces only
the types whose sum changed, so only those types' nodes are marked dirty. One source for all the
parts would mark every type of the holder, and everything below it, whenever any part changed.

**Exactness.** The values are fixed-point integers stored in doubles, well below 2^53. The sums, and
the core's delta updates of them, are therefore exact. A per-type sum is built in the parts' order,
as the build adds them.

**The triggers.**

- `src:scripts(f)` installs the extra triggers (`is_immortal`, `has_relic`) and the economy's links
  and triggers (`engine/economy/script.lua`, `script.with`) once for the whole update.
- Inside it, `S:with_script` only does `pcall(f, ...)` and creates no closure per trigger.
  `script.with` is unchanged: it is re-entrant, and its colony-to-planet scan now happens at most
  once per update instead of per trigger. The results are the same, since the world does not change
  inside.
- During an update, `src.trigger_memo` keeps each answer by (block, scope kind, scope id, file),
  but only for triggers with no `from`. Pass 2 repeats pass 1's triggers for the reading holders,
  and now answers them from the memo. The world does not change in between, and the triggers read
  no graph that changes in between (G2 is changed in step 5). This cut pass 2 from about 70 ms to
  about 20 ms.
- `S:active` reads each definition's triggered blocks once (`S:triggered_blocks`: values, potential,
  multiplier) and then only evaluates potentials and computed multipliers.

**Other changes to the parts code** (all exact, checked by the same comparison):

- `unq` no longer uses `gsub`.
- A ship's starbase lookup inverts `station_of` once per structure, where it had scanned every
  starbase for every ship.
- `st:parents` looks up its masks without concatenating strings.

**The source cache** (`world_source.lua`, `source.get`).

- It is no longer emptied. It drops the entries of the holders the update reports as changed
  (including the new and gone ones) and every miss (`false`), since a holder may now exist.
- `economy.invalidate()` is still called every time. It only drops the economy's budgets, which the
  budget phase computes anew every month anyway, so there was nothing to narrow.
- `source.stats.builds` still counts every update. `engine/store/bridge.lua` keys its ship values
  on it, so after an update it reads every ship again. Those reads are mostly cache hits now.

**The check** (`STELLAR_MODIFIER_CHECK=1`).

- Each rebuild first builds the graph whole (`mw.world_graph`, its own fresh source), then updates
  the incremental one.
- It compares every holder's `mw.values` (every type, both ways, exactly), the holder sets, and every
  values table still in `source.get`'s cache.
- The whole build comes first so that both read last month's modifiers through `source.get`.
- It prints the update's counters and a line per rebuild, and the totals at the end of the run.

`STELLAR_MODIFIER_INCREMENTAL=off` goes back to the whole rebuild every month.

## 3. Correctness

| gate | result |
|---|---|
| check mode, 180 days from 2210.01.01 (load + 6 months) | 7 rebuilds, 109,881 holders, 771,561 values: 0 differ, 0 missing, 0 extra; 21,892 cached values tables, 0 differ |
| `examples/diff ... t1798.gamestate 12` | 723,380 equal / 13,251 differ, 4,725,089 draws (unchanged) |
| `cargo test --release` | passes |

The updates of that run:

| update | holders (+ / -) | relinked | pass 1 changed | reading (pass 2 changed) | holders below a type change | dirty nodes | holders changed | ms |
|---|---|---|---|---|---|---|---|---|
| 1 (load) | 15,664 | 10,724 | 3,420 | 220 (220) | 15,664 | 0 | 15,664 | 529 |
| 2 | 15,672 (+8) | 22 | 24 | 220 (22) | 330 | 1,949 | 365 | 253 |
| 3 | 15,670 (+23 -25) | 37 | 38 | 220 (28) | 193 | 5,337 | 303 | 285 |
| 4 | 15,702 (+32) | 54 | 41 | 220 (28) | 344 | 7,513 | 409 | 271 |
| 5 | 15,706 (+4) | 12 | 27 | 220 (26) | 19 | 658 | 68 | 380 |
| 6 | 15,723 (+17) | 33 | 28 | 220 (24) | 474 | 6,536 | 510 | 277 |
| 7 | 15,744 (+21) | 49 | 45 | 220 (27) | 342 | 5,041 | 453 | 231 |

How a monthly update divides, in ms (structure, links, pass 1, pass 2, applied, changes):

| update | structure | links | pass 1 | pass 2 | applied | changes |
|---|---|---|---|---|---|---|
| 2 | 15 | 32 | 174 | 20 | 9 | 3 |
| 7 | 13 | 37 | 159 | 16 | 4 | 1 |

Allocation per update with the collector stopped (120 days, `tmp_sim/inc_alloc.lua`) was 52 MB,
against 213 MB before. Of that, 34.8 MB is pass-1 parts (25.0 MB of it inside the triggers, mostly
in the script layer), 1.5 MB is pass 2, and 15.6 MB is the rest (the structure's lists, links and
indexes).

## 4. Timings

Plain `examples/run` from the 2210.01.01 autosave, with no measuring hooks. "Before" runs are
sim-test at 7d2f1a5 (the store on by default). "After" runs are the same tree with this work
applied. B and A alternated, with nothing else of ours running. The 60-day rows come from two
rounds of two runs each.

| | days | phases in all (s) | `monthly.modifiers` (ms a call) | `monthly.budget` (ms a call) | load (s) |
|---|---|---|---|---|---|
| before | 60 | 12.8, 12.2, 12.1, 12.3 | 1,310, 779, 1,155, 803 | 666, 593, 615, 673 | 4.1 |
| after | 60 | 10.7, 10.6, 10.3, 10.5 | 474, 539, 444, 475 | 623, 471, 611, 575 | 3.8 |
| before | 180 | 32.4, 32.7 | 1,026, 945 | 587, 556 | 4.1 |
| after | 180 | 28.0, 30.3 | 324, 318 | 431, 417 | 3.8 |

- **Over 180 days**, the modifier phase drops from 6.2 / 5.7 s to 1.9 / 1.9 s, and the budget phase
  from 3.5 / 3.3 s to 2.6 / 2.5 s. The phase totals drop by 2.4 to 4.4 s. The second "after" run was
  noisy (`daily.script_state_expiry`, `daily.galaxy` and `daily.colonies_parallel` took 2.3 s more
  than in the first).
- **Over 60 days** (2 monthly rebuilds), the totals drop by about 1.8 s.
- **The load** builds the graph once (0.5 to 0.7 s, against 1.1 to 1.3 s for the two builds) and is
  0.3 s shorter.
- **The collector.** The modifier phase, 320 to 480 ms a call, is more than the update's own 230 to
  290 ms (the check runs). The rest is the collector's steps, paid where the allocation happens.
- **The budget in 60-day runs.** With only two months, the budget phase hardly moves, even though it
  computes 470 values tables instead of 4,050. The collector's cycle lands in it. Over 180 days it
  is 140 ms a month shorter.

## 5. Recompute and compare, or track changes

Pass 1 computes the parts of all ~15,700 holders, and on average about 30 of them change. It is now
most of the update (160 to 190 ms) and most of what it allocates. Of that time
(`tmp_sim/inc_cats.lua`):

- the 35 colonized planets, 150 pop groups and 55 countries are about 70% (their triggered blocks);
- the 6,000 uncolonized planets, 2,500 ships (13% on their own) and the rest share what is left.

A change tracker could in principle skip almost all of pass 1. It was not built, because it cannot
be made exact with what the engine has today:

- **Parts depend on triggers, and triggers read anything**: other objects through scope links,
  flags and variables, the date, other modifiers' values. A tracker would need, per holder, the
  set of what its triggers read (recorded through the script layer and `engine.world`), plus a way
  to see writes to those.
- **Writes bypass the API.** Much of the engine edits world tables in place. `docs/data_layer.md`
  §9 found the same problem for the store's mirror: it needed write marks in 8 modules and a check
  mode to find the writers it missed, and that covered only exploration's 11 stores and keys. The
  parts read far more: technologies, traditions, policies, edicts, timed modifiers, governments,
  ethics, situations, budgets, colonies, districts, zones, buildings, jobs, deposits, pop groups,
  species, leaders, councils, ships, designs, fleets, armies, starbases, sectors, federations and
  megastructures.
- A missed write gives a wrong modifier silently, until the next whole rebuild.

Recompute-and-compare costs the pass-1 time and is exact by construction. If the world's writers
ever mark what they change (the store's `live.touch`), a holder could be skipped when nothing it
read was marked. Its read set would come from the same instrumentation the check uses. The check
mode would then be the safety net, as `STELLAR_STORE_CHECK` is for the mirror.

## 6. On the store's workers, later

The per-holder parts computation is a good fit for the worker pool of `docs/data_layer.md` §8,
once its inputs are in the shared store:

- **Pass 1 is a pure function per holder** of the world, the definitions and the script state. It
  writes nothing. The only state shared between holders is caches:
  - caches of what was read from the files, which each worker can keep warm in its own state;
  - per-colony and per-country caches (shared pop parts, new-colony counts), which follow the
    holder order. A worker would take whole colonies (the planet, colony and pop groups together)
    and whole countries.
- **Split by cost.** About 240 holders are 70% of the time (colonized planets, pop groups,
  countries), so the pool should hand them out costliest first from the atomic counter, as
  exploration does, then hand out the cheap remainder in chunks.
- **What a worker returns**, per holder, is a fingerprint of its parts, or only the per-type sums of
  the holders whose fingerprint differs from the one it was given. The main thread keeps the graph:
  `stellar.graph.core` is single-threaded and the graph is the main state's. It applies the
  differences in record order. The sums are integers, so the order of addition does not matter, and
  the results do not depend on which worker computed them.
- **Pass 2** needs G1. After pass 1 the main thread updates G1, computes the values the reading
  holders read (last month's set of refs, plus any missed ones on the main thread), and publishes
  them to the store as a map. Pass 2 can then run on the workers for the 220 reading holders, or
  stay on the main thread: it is about 20 ms.
- **What has to be in the store first**:
  - every object and field the parts read (the list in §5);
  - the script layer able to evaluate triggers over the store on a worker (exploration's store
    port shows the pattern, but `simscript.eval` and `engine.interface` are table-based today);
  - the script state (flags, variables);
  - the modifier values that `check_modifier_value` and `modifier:x` read, which are last month's.
    The main thread can publish these before the pass, as the bridge publishes ship values.
- **The triggers are the hard part.** About 13,800 are evaluated per update, and they hold 25 of the
  52 MB allocated per update. That is also what the workers would win.

## Files and switches

- `sim/lua/engine/modifiers/incremental.lua` (new): the kept graph and its update.
- `sim/lua/engine/modifiers.lua`:
  - `S:refresh` (the source kept);
  - `S:scripts` and the `S:with_script` fast path (scripts installed once per update);
  - `ref_of` / `src.ref_used` (reading parts found);
  - `src.trigger_memo`;
  - `S:triggered_blocks` (definitions' triggered blocks read once);
  - `unq` without `gsub`;
  - the stations' inverse map.
- `sim/lua/engine/modifiers/structure.lua`: the masks looked up by category without string
  concatenation.
- `sim/lua/engine/economy/world_source.lua`: the incremental update by default, the narrowed cache,
  and the check.
- `sim/lua/engine/systems.lua`: the modifier phase's comment only.
- `STELLAR_MODIFIER_INCREMENTAL=off`: the whole rebuild every month, as before.
- `STELLAR_MODIFIER_CHECK=1`: a whole build every month, and every value compared.
- Measurement helpers, outside the repository, in `tmp_sim/`:
  - `inc_measure.lua` / `_report.lua`: the old rebuild's split, and month-to-month changes with
    `INC_CHANGES=1`;
  - `inc_cats.lua` (parts by category), `inc_alloc.lua` (allocation), `inc_budget.lua` (values
    computed in the budget);
  - `inc_timing.sh` (alternating runs) and `inc_apply.sh` (the patch onto sim-test).

**Notes.**

- `src.stats` diagnostics count once per definition, not per call, for what `S:triggered_blocks`
  caches: unresolved numbers, unknown keys and missing definitions met there. Its `triggers` counter
  no longer counts memoized answers. The script layer's own "trigger evaluations" count drops for
  the same reason.
- A trigger that flushed queued engine effects (`sync()`) in the middle of an update could change
  the world between pass 1 and pass 2. The whole rebuild had the same exposure between its two
  builds. The modifier phase runs with the queue flushed.
