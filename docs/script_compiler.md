# The script compiler (sim/)

The script layer of the simulation (`sim/lua/simscript/eval.lua`, "the walker") evaluates
triggers, script values and effects by walking pdxscript's trees, whose tokens are raw text. Every
evaluation lowercases each keyword again, finds its class (a handler, a scope chain, an iterator, a
scripted trigger, a flag, a property), splits scope chains with `gmatch`, runs `tonumber` on
values, looks up `@variables`, builds the cache key of a scripted trigger's instance and scans each
`if` for its `limit`. The compiler (`sim/lua/simscript/compile.lua`) does that work once per block:
every trigger block, value block, weight block, value text, scope chain and script value the walker
evaluates becomes a tree of Lua closures, cached on the block, and the walker stays as its
reference.

Everything here was measured on 10.5.0.24 (Ryzen 9 5900X) from the 2210.01.01 autosave, on the tree
9f1de91 plus this work. The box was shared with another agent's long run, so single timings carry
10 to 30% of noise; the on and off runs alternated.

## In short

- **Before**: 32% of the samples of a 60-day run had the walker on the stack, 22% in `eval.lua`
  itself (the rest is the handlers' engine reads). The daily country events (`countries_serial`)
  were 84% script, the AI's attitudes 73%, the AI 50%, pops 47%, the budget 40%.
- **What is evaluated**: 6.7 million trigger statements in 180 days, in 12,069 distinct trigger
  blocks. Half the evaluations are in 101 blocks, 90% in 1,250, 99% in 5,192. Effects are rare:
  75 blocks, 690 evaluations.
- **pdxast is not used for loading**: it parses the game's script 4.7 to 6.3 times slower than
  pdxscript and keeps 4.3 to 5.4 times the memory. Tokens are typed once per block at compile
  time instead, by the walker's own rules (which differ from pdxast's in places).
- **Closures, not generated source**: with the simulation's JIT settings, generated Lua (`load`)
  is faster once warm but slower on the first pass, sometimes blows up (one trace set per block),
  and costs 4 to 6 times as much to compile. Composed closures share their prototypes, so the
  traces stay few.
- **After**: the walker's share of the samples falls from 32% to 25%; `eval.lua`'s and
  `compile.lua`'s own time from 22% to 13%. The daily country events (`countries_serial`) take a
  third less (4.5 to 3.0 s over 180 days) and the AI's attitudes 30% less; pops 6%. The phase
  total falls by 6% over 60 days (11.2 to 10.5 s) and 7% over 180 (29.0 to 27.0 s), the means of
  three alternating runs each. The AI, the budget and the modifiers spend their script time in the
  handlers' engine reads, which the compiler does not touch. About 30 MB more live heap. See
  [Timings](#7-timings).
- **Correctness**: the check mode compares every compiled evaluation with the walker's: 4,605,974
  over 180 days, 0 mismatches, and the same 6,705,277 trigger evaluations. The 180-day diff is
  unchanged with the compiler and without (723,380 equal / 13,251 differ, 4,725,089 draws),
  `STELLAR_MODIFIER_CHECK=1` gives 0 differences, and `cargo test --release` passes.
- **Per-frame caching**: not added. Within a tick, a top-level trigger evaluation repeats (same
  block, scopes and file) 2% of the time. A scripted trigger's body on the same scope repeats 63%
  of the time, about a fifth of all statements, but nothing tells the evaluator that its inputs
  are unchanged. See [section 6](#6-per-frame-caching).

## 1. Measurements before

### Where the time went

A 60-day run with LuaJIT's sampling profiler (1 ms), each sample put in its phase and marked when
`simscript/eval.lua` was on the stack (`tmp_sim/compile/prof_eval_start.lua`, `prof_eval_dump.lua`):

| phase | samples | with the walker on the stack |
|---|---|---|
| daily.countries_parallel | 3,164 | 12.1% |
| ai.process | 1,935 | 50.4% |
| micro.update | 1,411 | 1.1% |
| daily.countries_serial | 1,382 | 84.2% |
| monthly.budget | 652 | 39.9% |
| monthly.modifiers | 600 | 29.7% |
| daily.pop_groups | 497 | 46.9% |
| daily.ships_fleets_armies | 473 | 2.7% |
| daily.ai_attitudes | 372 | 72.6% |
| monthly.countries_serial | 317 | 46.1% |
| daily.colonies_parallel | 280 | 7.1% |
| all | 11,678 | 31.6% |

Of all samples, 22.2% were the walker's own time (`eval.lua`), 7.0% the engine reads of the
handlers (`engine/world.lua`) and about 3% the rest of the handlers. In the walker's samples,
4.2 points of the 31.6 were in C functions (`lower`, `gmatch`, `gsub`, `match`, `tonumber`); with
the compiler 0.3. The JIT aborted 43,423 traces in 180 days with the walker and 27,536 with the
compiler; it flushed none in either.

### What is evaluated, and how often

Counted over 180 days by an instrumented walker (`tmp_sim/compile/eval_count.lua`,
`count_dump.lua`):

| unit | distinct | evaluations | seen once | half the evaluations in | 90% in | 99% in |
|---|---|---|---|---|---|---|
| trigger blocks | 12,069 | 3,684,978 | 3,817 | 101 | 1,250 | 5,192 |
| trigger statements | 17,180 | 6,705,277 | 3,575 | 142 | 1,861 | 8,186 |
| value blocks | 84,571 | 86,271 | 84,560 | | | |
| weight blocks | 223 | 42,005 | 15 | 18 | 121 | 168 |
| effect blocks | 75 | 690 | 23 | 2 | 36 | 69 |

The hottest blocks are scripted triggers and on_action conditions: `is_valid_fallen_empire_for_task`
(168,300), the fallen machine empire's task event's `any_country` (108,900), the game rules
`system_blocks_sensors` and `can_force_see_fleets_in_system` (107,280 each), `has_crisis_stage_*`.
The value blocks are nearly all new tables built by their callers for one evaluation
(`engine/economy/script.lua`'s `value_with_complex`).

The statements by what the walker found them to be:

| kind | evaluations |
|---|---|
| a handler in `TRIG` | 2,999,737 (or 593,089, has_global_flag 473,268, has_modifier 464,778, has_trait 222,548, exists 141,356, is_tutorial_level 109,929, is_inside_nebula 107,281, and 106,582, not 97,383, ...) |
| a property (`is_country_type = x`, `has_authority = x`) | 1,591,191 |
| a scripted trigger | 988,581 |
| a flag | 640,039 |
| a scope (`owner = { }`) | 303,871 |
| not known (counted as missing) | 138,066 |
| an iterator (`any_`, `count_`) | 43,792 |

31 statements changed kind during the run: the modules' `script.with` install handlers and links
and take them out again, so a keyword is a handler in one phase and a scripted trigger or a link in
another.

### pdxast against pdxscript

`lib/stellar-lua-pdxscript` at master (6fa477d), the 2,234 files of `common/**/*.txt` and
`events/*.txt` (32.4 MB), every tree kept (`tmp_sim/compile/parse_bench.lua`, the simulation's
LuaJIT):

| parser | time | rate | memory of the trees |
|---|---|---|---|
| `pdxscript.parse` | 0.84 s | 38.7 MB/s | 443 MB |
| `pdxast.parse`, `semantic = false` | 3.94 s | 8.2 MB/s | 1,900 MB |
| `pdxast.parse` (with pdxreader's reading) | 5.27 s | 6.1 MB/s | 2,373 MB |
| `pdxast.parse` then `pdxast.tree` (the AST dropped) | 4.10 s | 7.9 MB/s | 439 MB |

The simulation loads in about 4 s, so parsing with pdxast would add 3 to 4.5 s and 1.5 to 2 GB.
The scripted triggers, effects and values are also parsed again at run time for each set of
arguments (`source.instantiate`, through pdxscript), so a parse-time typing would not reach them.

## 2. Typed once: what is resolved at compile time

The compiler types each token once, when its block is compiled, by the walker's rules:

- **Keywords**: lowercased once; their class is fixed when it cannot change (an iterator's name, a
  flag's name, a property, a scope chain's parts) and looked up at call time when it can (a handler
  in `TRIG`, a link in `LINKS`, a list in `LISTS`, a scripted trigger in `db`).
- **Numbers**: `tonumber` once. The walker reads `inf`, `nan`, `1e3` and `0x10` as numbers (and a
  number with blanks around it), which pdxast types as words; `2200.01.01` is no number for either.
- **Scope chains**: split into links once (`event_target:` / `scope:`, `last_created_`, a link
  first, a link after the first), each link's function looked up at call time.
- **`@variables`**: a scripted variable is the file's (`ctx.file`) or the global one, the same for
  the whole run, so each value text keeps its variable per file: one lookup per file, then the
  variable's own text compiled as a value.
- **Inline math** (`@[ ... ]`): left to the walker's `mathexpr` (it is rare; its variables depend on
  the file).
- **Script values** (`value:name|P|v|`): the spec split once, the instance looked up once per
  definition.
- **Scripted triggers**: the call's instance (`db.instance`) once per definition; the "count form"
  (`pop_amount > 10`: a body of one count iterator) found once.
- **if / else_if / else**: each branch's `limit` found once, the chains grouped once.

## 3. Closures or generated source

Both were tried on a synthetic workload shaped like the simulation's (properties, flags, scripted
triggers, OR and NOT, scope links, handlers looked up at call time) with the simulation's JIT
settings (`maxtrace=40000`, `maxside=400`, ...; `tmp_sim/compile/bench_style.lua`), in ns per
statement:

| workload | walker | closures | generated (`load`) |
|---|---|---|---|
| 400 blocks, 40 scopes, 60 rounds, first pass (4 seeds) | 94 to 128 | 50 to 68 | 47 to 166 |
| the same, second pass | 99 to 117 | 43 to 60 | 26 to 148 |
| 6,000 blocks evaluated with the simulation's spread, compiled on first use | 184 to 249 | 159 to 205 | 273 to 345 |
| the same, second pass | 174 to 225 | 118 to 191 | 143 to 172 |
| compile time | | 3 to 5 us a block | about 19 us a block |

Generated source gives each block its own function, so LuaJIT keeps a set of traces per block:
fast once warm, but slow to warm up, sometimes pathological (one of the four seeds: 148 to 166 ns
on both passes), and with LuaJIT's default limits slower than the walker (124 to 278 ns). The
simulation makes about 14,000 traces in 60 days (33,000 started) under a limit of 40,000; one set
per block would add a set for each of thousands of blocks. Closures share a few dozen prototypes,
so their traces serve every block of the same shape. The compiler uses closures.

## 4. Design

### The units and their caches

| unit | compiled into | cached by | compiled when |
|---|---|---|---|
| trigger block, per skip set | `function(ctx) -> bool` | the block table (weak), one cache per skip table | its 2nd evaluation; its sub-blocks with it |
| value block (`apply_ops`), with or without `only_ops` | `function(ctx, acc) -> acc` | the block (weak) | its 2nd evaluation |
| weight block (`M.weight`) | `function(ctx, base) -> acc` | the block (weak) | its 2nd evaluation |
| value text | `function(ctx, e) -> value` | the text (numbers are not kept) | its first evaluation |
| scope chain (`M.resolve`) | `function(ctx, e) -> found, scope` | the text | its first evaluation |
| script value spec | `function(ctx, e) -> value` | the spec | its first evaluation |

A block seen once is only walked (`STELLAR_SCRIPT_COMPILE_AFTER`, default 2): most value blocks are
built by their callers for one evaluation. The text caches are emptied past 100,000 entries. The
blocks are the definitions' trees, which live for the run, and the instances of scripted triggers
and values come from `db.instance`'s cache, so the same block table comes back on every call.

A compiled block compiles its sub-blocks with it (`AND`, `OR`'s statements, `if` bodies and limits),
except those behind a branch a statement takes only at call time: a scripted trigger's body (its
definition is looked up when it is called), an iterator's body, and the block of a keyword that is
a scope (a link may be installed by a module only for a while).

### Where the compiler plugs in

`eval.lua` exposes its locals to the compiler (`M._internal`) and lets it replace the `trigger`,
`apply_ops` and `value_text` its walker calls (`_internal.set`). The compiler installs dispatchers
there and in `M.trigger`, `M.value_text`, `M.resolve`, `M.script_value` and `M.weight`: each looks
up the compiled unit, compiles it when its time comes, or walks. The walker's own functions are kept
(`trigger_tree`, `apply_ops_tree`, `value_text_tree`, the original `M.resolve`, `M.script_value`,
`M.weight`) as the reference. `STELLAR_SCRIPT_COMPILE=off` leaves `eval.lua` alone; the only
changes to the walker are that `trigger`, `apply_ops` and `value_text` are locals the compiler can
set, that `trigger1` is split in two (`trigger1_rest`: everything after the handler lookup), and
that two skip tables are constants instead of new tables on every call.

### A statement

A statement compiles to one closure that does what `trigger1` does, in its order; the branch it
takes after the handler lookup (the scope, the iterator, the scripted trigger, the flag or
property) is compiled when the statement first takes it, since most statements only ever take one:

1. count it (`stats.trigger_evals`);
2. look its keyword up in `TRIG` at call time: eval.lua's own `or`, `not`, `nor`, `and`,
   `hidden_trigger`, `nand`, `custom_tooltip`, `calc_true_if`, `always`, `exists`,
   `has_global_flag` and `has_modifier` run inlined while `TRIG` still has eval.lua's function,
   any other handler is called;
3. a scope reference: a keyword whose first part is a link in `LINKS` at call time, or a saved
   target or `last_created_` (always);
4. an `any_` / `count_` iterator over `list_of` (`LISTS`, `AMOUNTS` at call time);
5. a scripted trigger, if `db.scripted_triggers` has one at call time;
6. a flag, a property, an unresolved `@` / `$`, or a miss.

Steps 3 and 6 inline `M.resolve` and `M.property`; the closure first checks that they are still the
ones installed (else the statement goes to the walker's `trigger1`).

## 5. The semantics matched

The check mode (below) found these by construction or by a mismatch; each is the walker's, kept:

- **The dispatch order** of a statement, above, at call time: `TRIG`, `LINKS`, `LISTS`, `AMOUNTS`,
  `db`'s definitions, `M.script_value` (replaced by `engine/economy/script.lua` inside
  `script.with`), `M.value`, `M.count_items`, `M.count_value`, `M.store`, `E`.
- **AND blocks**: the skip set (parameters such as `limit`, `count`, `text`); an `if` resets
  `taken`, an `else_if` or `else` anywhere after any statement reads it; a taken body is evaluated
  with `limit` skipped and ends the block when false.
- **OR, NOT, NOR, calc_true_if** (`holding`): an `if` and the `else_if` / `else` statements right
  after it (other entries between them skipped) are one trigger, true when no branch is taken; a
  stray `else_if` / `else` is false and not evaluated; `calc_true_if`'s skip (`amount`) applies to
  the other statements only, and every `amount` is evaluated in order, the last one winning.
- **Scopes**: `owner = root` resolves both sides even when the left one is none; `owner = { }` is
  false when there is none; a chain's first part that is no link is no scope reference, a later one
  is a miss; `last_created_` flushes the engine queue before resolving its handle.
- **Iterators**: `any_` stops at the first true; `count_` evaluates every `count` (the last wins;
  `all` is -1, which also means "all" when a value comes out as -1).
- **Scripted triggers**: evaluated in the definition's file (`with_file`); `= no` negates; a failed
  instance misses on every call; the count form only when the body is one statement and
  `count_value` gives a number.
- **Flags**: `x@root` is `x@<id>` (or `x@none`), resolved on every call; `@[` is no scope.
- **Properties**: false on no scope; the engine queue flushed first; `has_building` and `has_edict`
  read the sets `building` and `edict`; yes/no compares with `"yes"` or `true`; anything else
  compares `tostring`.
- **Value texts**: `tonumber` (with `inf`, `nan`, exponents and hex), yes/no, inline math, the
  scripted variable of the file or the global one (read again as a value), `value:`, `trigger:`
  (a miss), `modifier:`, a variable behind a chain (0 when the chain finds no scope), a variable,
  a script value of the name, 0.
- **Value blocks**: the `only_ops` filter (which also drops `if`); `min` takes the larger, `max` the
  smaller; division and modulo by 0 leave the value; `modifier` blocks with their triggers'
  parameters skipped; `count_<list>` blocks and scope blocks; misses for the rest.
- **Weights**: `base`, `factor`, `weight`, `days` set; `months` and `years` scale; `modifier` blocks
  multiply, add and subtract in order.
- **Counts**: one trigger evaluation per statement the walker evaluates, every `miss` in order (its
  first location), every `sync`.
- **Errors**: what the walker works out on each call and could fail on (an instance) is worked out
  on the call, not ahead; a statement or block that fails to compile is walked.
- **Draws**: triggers and values draw nothing. Effects are not compiled (690 evaluations in 180
  days); they are walked, with their limits, weights and values compiled, so every draw is the
  walker's, in its order.

### The check mode

`STELLAR_SCRIPT_CHECK=1` follows every compiled evaluation (trigger block, value block, weight,
value text, scope chain, script value) with the walker's on the same input, with the walker's
misses and trigger evaluations kept out of the counts, and compares the results and the number of
statements evaluated. The report line `script compiler check` gives the number compared and the
mismatches by kind and block. (Its first version counted the statements of the walker's runs in
nested checks into the compiled side; with that fixed it has found no mismatch.) A block's first
evaluation is the walker's alone, so the check covers every evaluation from the second on.

Over 180 days from 2210.01.01: 4,605,974 evaluations compared, 0 mismatches, 6,705,277 trigger
evaluations as without the compiler. Shapes the run may not reach are in
`tmp_sim/compile/edge_test.lua` (run with `STELLAR_LUA`, in check mode, after one day): if chains in
AND and OR blocks, a stray `else`, `calc_true_if` with an if chain, `count_` with `all`, flags with
`@root`, `owner = root`, `exists` of a missing target, `NOR` / `NAND`, value blocks with if chains,
`min` / `max`, division by 0, `@` variables that do not exist, weights with `months` and `years`,
on no scope, countries and planets: 3,021 evaluations compared, 0 mismatches.

## 6. Per-frame caching

Measured over 60 days (`tmp_sim/compile/compile_memo.lua`), keyed by the tick:

- **Top-level trigger evaluations** (from the engine and the handlers): 655,802. The same block,
  skip set, scopes (this, root, from, prev, prevprev) and file again in the same tick: 13,237
  (2.0%), holding 4.5% of the statements. None gave another result. Too little to pay for building
  the key.
- **Scripted trigger bodies** on the same `this` scope in the same tick: 211,113 of 333,187 (63.4%),
  holding 442,649 of the 890,206 statements evaluated in scripted bodies (about a fifth of all
  statements). None gave another result in 60 days. The top ones: `is_valid_fallen_empire_for_task`
  (68,155 statements), `is_crisis_faction` (50,124), `is_design_space_fauna`, `has_starborne_biology_mutation`,
  `is_mechanical_empire`, `has_crisis_stage_3`, `is_regular_empire`, `can_think`.

Not added: it is not exact. A cached result is only valid while its inputs are unchanged, and
nothing tells the evaluator that: effects set flags and variables inside a tick, the Lua systems
change the world directly (pops, economy, modifiers), and the handlers of other modules may read
scopes other than `this`. It would apply to scripted trigger bodies, with:

- a write epoch bumped by every change to the world (`engine/world.lua`'s setters, the stores),
  by `M.store`'s setters and by the engine queue's flush, and checked by the cache;
- a key of the scopes the body reads (`this` for most), found when it is compiled, with handlers
  declaring what they read;
- the cached statement counts and misses added on a hit, so the reports stay the same.

No draws happen in triggers or values, so there is nothing of the draws' to cache there. Scripted
variables, which are constant for the run, are resolved once per file (section 2).

## 7. Timings

Alternating runs of `examples/run`, off then on, three of each, on one core
(`tmp_sim/compile/timing.sh`, `timing_table.sh`): the phase total and the phases with most script,
in seconds, and the change of the means.

| 60 days | off (s) | on (s) | change |
|---|---|---|---|
| total | 11.0 / 11.4 / 11.2 | 10.3 / 10.4 / 10.9 | -6% |
| daily.countries_serial | 1.49 / 1.51 / 1.56 | 1.00 / 1.01 / 1.02 | -34% |
| daily.ai_attitudes | 0.39 / 0.41 / 0.41 | 0.28 / 0.29 / 0.28 | -30% |
| daily.pop_groups | 0.45 / 0.47 / 0.50 | 0.46 / 0.44 / 0.42 | -6% |
| ai.process | 1.76 / 1.75 / 1.64 | 1.56 / 1.88 / 1.68 | -1% |
| monthly.budget | 0.56 / 0.56 / 0.62 | 0.55 / 0.58 / 0.58 | -2% |
| monthly.modifiers | 0.52 / 0.52 / 0.54 | 0.57 / 0.52 / 0.51 | +0% |
| monthly.countries_serial | 0.31 / 0.31 / 0.29 | 0.29 / 0.28 / 0.29 | -3% |
| daily.countries_parallel | 2.80 / 2.75 / 2.90 | 2.75 / 2.64 / 3.32 | +3% |
| micro.update | 1.45 / 1.58 / 1.41 | 1.55 / 1.48 / 1.45 | +1% |

| 180 days | off (s) | on (s) | change |
|---|---|---|---|
| total | 28.3 / 28.2 / 30.6 | 28.2 / 26.3 / 26.6 | -7% |
| daily.countries_serial | 4.65 / 4.25 / 4.50 | 3.11 / 2.93 / 2.95 | -33% |
| daily.ai_attitudes | 1.17 / 1.05 / 1.07 | 0.76 / 0.80 / 0.78 | -29% |
| daily.pop_groups | 1.25 / 1.25 / 1.26 | 1.17 / 1.09 / 1.24 | -6% |
| ai.process | 3.93 / 4.09 / 4.06 | 4.18 / 4.19 / 3.98 | +2% |
| monthly.budget | 1.52 / 1.51 / 1.60 | 1.60 / 1.40 / 1.47 | -3% |
| monthly.modifiers | 1.47 / 1.46 / 1.51 | 1.62 / 1.42 / 1.44 | +1% |
| monthly.countries_serial | 0.87 / 0.94 / 0.93 | 0.98 / 0.86 / 0.88 | +0% |
| daily.countries_parallel | 6.89 / 6.84 / 8.96 | 7.26 / 6.76 / 7.10 | -7% |
| micro.update | 3.06 / 3.12 / 3.16 | 3.34 / 3.09 / 3.22 | +4% |

Two earlier rounds of two runs each gave -1% and -9% over 60 days and -10% and -3% over 180, the
same phases moving the same way: the country events and the AI's attitudes by a third, the rest
within the noise. Single runs move by up to a second with where the collector runs (one compiled
180-day run had `script_state_expiry`, `galaxy` and `colonies_parallel` each a second slower, with
no script in them).

The phases that are mostly script but did not gain spend it in the handlers, not in the walker: in
`ai.process` (46% of its samples with the walker on the stack) the walker's own functions were
about 15% of the phase, the engine reads of the AI and its handlers (`world.fields`, `world.list`,
`defs.field`) most of the rest.

Where the time of the compiled runs goes (60 days, profiler): 24.8% of the samples have the
evaluator on the stack. Of all samples, `compile.lua`'s closures are 8.3% (mostly the call-time
lookups and the calls between closures), `eval.lua` 4.4% (the context tables: `new_ctx` for each
evaluation from the engine, `push` for each scope change, `S`'s string key for each scope), and
the handlers' engine reads 7.4%. The compilation itself takes 0.08 s over 60 days and over 180
(8,370 trigger blocks, 18,600 statements, 3,149 scope chains, 208 weights, 15 value blocks over
180 days). The compiled closures keep about 30 MB of the live heap: 1,064 to 1,077 MB after a full
collection without them, 1,094 to 1,113 MB with them.

## 8. Switches

| variable | effect |
|---|---|
| `STELLAR_SCRIPT_COMPILE=off` | the walker alone |
| `STELLAR_SCRIPT_COMPILE_AFTER=n` | compile a block at its n-th evaluation (default 2) |
| `STELLAR_SCRIPT_CHECK=1` | every compiled evaluation compared with the walker's |

The report has a line `script compiler: ...` with what was compiled, and in check mode
`script compiler check: ...`.

## 9. What is left

- `S(kind, id)` builds a string key on every call, `new_ctx` makes four tables per evaluation
  and `push` copies twelve fields per scope change: about 4% of the run, in both modes.
- The handlers' own engine reads (`world.field`, `world.fields`, `world.object`, `defs.field`) are
  now the larger part of the script time.
- `engine/economy/script.lua`'s `script_value` (installed inside `script.with`) still splits the
  spec, substitutes the caller's variables and builds the instance key on every call before it
  hands over to the compiled script value.
- Effects are walked; they are too rare to matter today.
- The files of this work's measurements are in `tmp_sim/compile/` (hippo share): the profilers
  (`prof_eval_*`, `prof_phase_*`), the counts (`eval_count.lua`, `count_dump.lua`), the parse and
  style benchmarks, the per-frame measurement (`compile_memo.lua`, `memo_*`), the JIT counters
  (`jit_*`), `apply.sh` (the work onto sim-test) and `timing.sh`.
