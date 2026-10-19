# Script coverage: every documented keyword wired to Lua that does something

The goal is full coverage of the game's script language, not parity on a sample: every trigger,
effect and scope link the game documents has a Lua implementation, and each one does what its
documentation says. The game cannot reproduce its own runs at the scale a full parity check would
need, so the reference is the game's own **script documentation**: which keywords exist and the
scopes each one supports (see [script_docs.md](script_docs.md)). Behaviour is then checked keyword
by keyword: against the docs, and against the real game where a headless run can show it.

`sim/lua/simscript/scriptcheck.lua` measures it. The runner is `sim/tools/scriptcheck_run.lua`.

## Inputs

- **The documentation.** The game writes it at every start to
  `Documents/Paradox Interactive/Stellaris/logs/script_documentation/` (`triggers.log`,
  `effects.log`, `scopes.log`, `localizations.log`, `modifiers.log`). It is not in the repository;
  copy it once (the 4.5.2 Steam dump is on the share, `code_working/tmp_scriptdocs/4.5.2-steam`).
- **One use of every keyword.** The docs mod from
  `lib/stellar-lua-pdxscript/tools/docs_mod/make_docs_mod.lua <docs dir> <game dir> <out dir>`.
  Its `manifest.tsv` gives each use's file, line and documented scope: 1,084 of 1,098 triggers,
  1,070 of 1,080 effects and all 99 links are placed. The rest are listed with a reason
  (deprecated, debug-only, or no scope reaches them).
- **A world.** A save loaded by `examples/run.rs`. The dynamic part's effects change it, so use
  a throwaway load.

## Running it

```
cd sim
STELLARIS_DIR=<game dir> SCRIPTCHECK_DOCS=<docs dir> SCRIPTCHECK_MOD=<docs mod dir> \
SCRIPTCHECK_OUT=<report.tsv> STELLAR_LUA=tools/scriptcheck_run.lua \
cargo run --release --example run -- 0 <save.sav>
```

It takes about 10 s on 10.5.0.24. Without `SCRIPTCHECK_MOD` only the static part runs.
`SCRIPTCHECK_COVERAGE=1` also fills the TSV's `vanilla_uses` column from `simscript.coverage`.
That column is informational only: coverage is the goal whether vanilla uses a keyword or not.

## What it reports

**Static**, from the documentation and the Lua's tables:

- **Each documented trigger and effect:** its status from `eval.status`: `lua` (a handler), `property`, `flag`, `iterator`, `event`, `scripted`, `engine-unmodelled`, or `missing`.
- **Each scope link:** `lua` (in `eval.LINKS`) or `missing`.
- **Missing keywords:** counted by the first scope the game documents for them.
- **Invented:** handler names the Lua registers that the game doesn't document (an old name, a typo, or the game's name is different).
- **Each effect handler's own source:**
  - whether it records itself as unmodelled on some path;
  - which engine effects it pushes, and whether `engine.systems.effects` has an applier for each;
  - whether its body is empty.

**Dynamic**, from the docs mod's use of each keyword. Each use runs in the first object of its documented scope in the world, and the check measures what it did:

| result | meaning |
|---|---|
| `missing` | the walker recorded a miss: no handler for the keyword (or a parameter the handler does not read) |
| `error` | a Lua error |
| `unmodelled` | the handler recorded itself as not modelled |
| `no applier` | an engine effect was queued that no system applies |
| `refused` | the engine effect's applier ran and applied nothing |
| `acted` | the world was written, an engine effect applied, or script state (flags, variables, targets) changed |
| `container` | control flow, iterators, tooltips and logs whose documented use changed nothing (their body did nothing) |
| `silent` | ran without error and changed nothing: a handler that does nothing for this use, to review |
| `evaluated` | a trigger evaluated (true or false) |
| `no object in scope X` | the save has no object of that scope: needs a save that has one |

The TSV has one row per documented keyword: its scopes, static status, vanilla uses, dynamic
result, the counts behind it (missing, unmodelled, unapplied, applied, world writes, script
writes), the handler's file and line, and notes (pushed engine effects, errors). Invented
handler names follow, one row each.

## The state on 2026-10-19 (master 00f6b20, the 2210.01.01 save)

| | documented | done | missing |
|---|---:|---:|---:|
| triggers | 1,098 | 493 (lua 339, iterator 93, flag 31, property 30) | 605 |
| effects | 1,080 | 348 (lua 100, iterator 138, flag 92, event 18) | 732 |
| scope links | 99 | 40 | 59 |

Missing by first documented scope:
- **Triggers:** country 224, planet 89, all 72, galactic_object 38, pop 30, ship 25, leader 14, fleet 13, starbase 11, espionage_operation 10, megastructure 10, archaeological_site 9, and smaller groups.
- **Effects:** country 289, all 98, planet 84, galactic_object 33, ship 27, fleet 24, leader 22, pop 20, megastructure 18, federation 15, starbase 13, agreement 12, cosmic_storm 11, and smaller groups.

Dynamically:
- 124 effects acted.
- 98 were containers.
- **23 effects ran silently:** add_anomaly, add_opinion_modifier, add_stage_clues, assign_leader,
  auto_move_to_planet, begin_event_chain, clear_fleet_actions, create_colony, create_pop_group,
  destroy_fleet, destroy_situation, enable_special_project, kill_leader, link_wormholes,
  merge_species, remove_auto_move_target, remove_opinion_modifier, run_ai_strategic_war_data,
  set_controller, set_location, set_owner, set_surveyed, set_update_modifiers_batch.
- **12 were refused by their applier:** abort_special_project, add_building, add_district,
  add_event_chain_counter, add_zone, end_event_chain, remove_building, remove_deposit,
  remove_district, remove_modifier, set_capital, set_fleet_stance.
- 14 links were silent.
- 160 uses had no object of their scope in this save: agreements, wars, espionage operations,
  cosmic storms, astral rifts and the like.

13 handler names are invented. A silent or refused result can come from the docs mod's example
(a target that doesn't exist, a condition that fails) as well as from the handler, so each one
needs reading.

## Not covered yet

- **Scope validity:** whether each keyword is refused in the scopes the game doesn't support. The check runs each keyword only in its first documented scope.
- **Parameters:** whether a handler reads every parameter the documented syntax names.
- **Modifiers:** checked separately by `examples/modcheck.rs` ([modifiers.md](modifiers.md)).
- **Localisation commands:** the 333 documented commands are read, but not yet checked against the localisation engine.
- **Behaviour:** what each keyword does is only verified where a headless run of the real game can show it (`headless/`, the `console` command), keyword by keyword.
