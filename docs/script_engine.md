# The script engine (4.5.2)

Reverse engineered from the GOG 4.5.2 build and its PDB, and read at runtime in the Steam 4.5.2
build by `lua/stellar/script/catalog.lua`. Addresses are GOG RVAs unless noted.

## How script becomes objects

1. **Tokens.** Every key the reader understands is an `int` token id. `CStaticLexer`, a singleton
   (`CStaticLexer::AccessStaticLexer`, instance `0x35ddf00`), maps names to ids. 10,004 tokens are
   compiled in (`GetTokenArray`, a 250 KB function of `CToken::CToken(id, name)` calls, ids 11 to
   18958); the rest are added at runtime by `CStaticLexer::AddDynamicToken` (ids from
   `_nBase + 1`): the list iterators (`every_*`, `random_*`, `any_*`, `count_*`, `ordered_*`) at
   startup, and every key the game reads from script files while it loads. In a loaded game there
   are about 60,000. `CStaticLexer::GetString(id)` is `_LookUp[id]` (`+0x70`, 48-byte strings), valid
   when `_LookUp._nSize (+0x7c) == _DesiredLookup (+0x80)`.
2. **Entries.** `CTriggerDatabase` (`CTriggerDatabase::_pTriggerDatabase`, `0x3100bb8`) and
   `CEffectDatabase` (`CEffectDatabase::_pEffectDatabase`, `0x313e848`) map a token id to an entry:
   `std::map<int, CTriggerEntryBase *>` at `+0x88` / `std::map<int, CEffectEntryBase *>` at `+0x18`.
   An entry is `{ vtable, const char *_szDescription }`; `vtable[1]` is `Create`, which allocates
   the object (`mov ecx, size; call operator new`) and stores its class's vtable.
   `CTriggerEntry<CHasTechnologyTrigger>::Create` makes a `CHasTechnologyTrigger`, and so on: 1,098
   triggers and 1,080 effects in 4.5.2, exactly the entries of the game's own documentation.
3. **Reading.** `CTrigger::Read` / `CEffect::Read` read a block: for each key, the token's entry
   creates the object, whose `ReadMember` / `Assign` read its parameters. Keys without an entry are
   scripted triggers and effects (`CScriptedTrigger`, `CScriptedEffect`), scope changes
   (`CContextTrigger`, `CContextEffect`: `owner = { }`, `event_target:x = { }`; the links are a
   switch in `CEventTarget::GetScope`), or blocks (`CAndTrigger` for `limit = { }`, `CEffect` for
   `immediate = { }`, `CTriggerMTTHModifier` for `modifier = { factor = 2 ... }`,
   `CRandomListEffect::CEntryEffect` for `random_list` entries).
4. **Evaluation.** `CTrigger::Evaluate` -> `ActualEvaluate` (404 classes have their own),
   `GetTriggerValue` for comparisons (241), `CEffect::Execute` -> `ExecuteActual` (540). Every class
   also has `GetSupportedScopes`, `GetSupportedScopeTargets`, `GetToolTip` / `GetDesc`.

Every compiled trigger is in `CTriggerDatabase::_Triggers` (a robin hood set at `+0x8`: entries at
`+0x10`, size `+0x18`; slots of `{ hash, distance + 1, CTrigger * at +8 }`), every effect in
`CEffectDatabase::_Effects` (a `CPdxArray` at `+0x0`).

The game also documents all of this itself, at startup, in
`Documents\Paradox Interactive\Stellaris\logs\script_documentation` (`triggers.log`,
`effects.log`, `scopes.log` with the 99 scope links, `modifiers.log` with 45,583 modifiers,
`localizations.log`): names, descriptions, syntax examples, supported and output scopes.

## What Lua reads (`stellar.script.catalog`, `stellar.script.docs`)

`catalog.locate(image)` finds, with stellar-fnmatch signatures (`lua/stellar/functions.lua`):

| | how |
|---|---|
| the lexer | the `lea rax, [rip+x]` in `CStaticLexer::AccessStaticLexer` |
| `_pTriggerDatabase`, `_pEffectDatabase` | `CScriptListsRegistryHelper<CAgreementListBuilder>` creates them when missing: `mov reg, [rip+x]; test; jne; call CTriggerDatabase::CreateInstance`, and `...; lea ecx, [reg+112]; call operator new` (112 = `sizeof(CEffectDatabase)`) |
| the structural classes | one method each (`CScriptedTrigger::ActualEvaluate`, `CContextTrigger::ReadMember`, ...): a vtable holding it is that class |

Same addresses as the PDB in GOG 4.5.2 (`tools/dry_run.lua`), and resolved in Steam 4.5.2 and GOG 4.5.1.

`catalog.read()` then reads, with checked reads, once the game has loaded: every token name, every
trigger and effect entry (token, name, description, `Create`), and decodes each `Create` for the
object size and vtable. The decoder follows folded `jmp`s and out-of-line constructors and only
counts the vtable stored through the register holding the new object; on the 824 `Create`s whose
vtable the PDB names it is right for all, finds no vtable for 1, and two others (of 2,166) take a
member's vtable (`CPersistentName`). 2,152 distinct vtables; the few shared ones are aliases
(`owned_planet` / `owned_colony`, planet / colony carrier flags).

In the game (Steam 4.5.2, a 2200 save), at startup (`lua/init.lua`, written to
`cache/script_catalog-<md5>.tsv`):

```
script: 60065 tokens (lookup 69009, 50050 dynamic from id 18959), 1098 triggers, 1080 effects, 2152 distinct object vtables
script: triggers: 1098 registered, 1098 documented; 0 not documented, 0 documented but not registered
script: effects: 1080 registered, 1080 documented; 0 not documented, 0 documented but not registered
script: 99 scope links documented, 99 of them are tokens
script: compiled triggers: 1215870 objects, 1215776 named (100.0%), 884 keywords used; most used:
  (trigger block) 231908, and 168577, (scripted trigger) 110923, (scope trigger) 71311,
  (modifier block) 60495, or 58534, has_government 41965, not 29990, has_country_flag 27497,
  has_ethic 27153, exists 25205, is_country_type 21387, has_trait 17267, has_valid_civic 17178, ...
script: compiled effects: 424716 objects, 424657 named (100.0%), 802 keywords used; most used:
  (effect block) 126566, if 39365, (scope effect) 34073, (random_list entry) 15792,
  (scripted effect) 15703, add_building 10699, hidden_effect 10552, country_event 8844,
  save_event_target_as 7427, set_country_flag 7423, custom_tooltip 7107, add_modifier 6182, ...
script: census in 2.80s
```

`catalog.identify(c, object)` names any compiled trigger or effect object by its vtable.

## Toward a Lua script layer

The aim: do the script work in Lua, and keep the C++ engine for what only it can do.

- **Syntax.** `pdxscript` ([stellar-lua-pdxscript](https://github.com/MattMills/stellar-lua-pdxscript),
  `lib/stellar-lua-pdxscript`) reads script text into a tree.
  Two independent readings of the same files, ours and the game's compiled objects, can be compared
  node by node: the census gives every object its keyword.
- **Script state and script effects.** Flags, variables, saved event targets, timers: the state
  the script layer owns. Effects on it (`set_country_flag`, `set_variable`,
  `save_event_target_as`, ...) and triggers that read it (`has_country_flag`, `check_variable`, ...)
  can live entirely in Lua, and are then consistent immediately. This state has to be saved with the
  game, and mirrored to the engine while native code (UI, AI, triggers not moved yet) still reads it.
- **Engine effects** (`create_ship`, `add_building`, `add_resource`, `add_modifier`, ...) change
  what only the C++ engine simulates. They cross from Lua to the engine through a queue that is
  applied on the main thread at a fixed point of the tick, in a deterministic order (multiplayer).
  Script that reads the result of an engine effect within the same event (`last_created_ship`, a
  resource comparison after `add_resource`) needs a flush barrier at that read, or a Lua model of
  the pending change.
- **Engine reads** (`has_technology`, `num_ships`, `is_planet_class`, ...): reads of the game
  database, through the FFI (`stellar.game`: the game state and its database), or by calling the
  compiled native trigger while it is not ported.
- **Speed** comes from what Lua can do that the C++ tree-walker does not: compile script to Lua
  functions LuaJIT traces, cache results per scope and tick (tooltips recomputing fleet modifiers),
  and skip work that cannot change. A shadow mode, running the Lua evaluation next to the native
  one on live game states and comparing results and times, shows what is right and faster before
  anything is switched over. Modifiers and localization strings follow the same pattern.
