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
object size and vtable. The decoder follows folded `jmp`s and out-of-line constructors, only
counts the vtable stored through the callee-saved register holding the new object, and stops at an
epilogue that ends the function (a `pop; ret` also occurs inside a call's offset); on the 1,527
`Create`s (of 2,166) whose vtable the PDB names it is right for all, and it finds one for every
`Create`. 2,154 distinct vtables; the few shared ones are aliases (`owned_planet` /
`owned_colony`, planet / colony carrier flags).

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

## Shadow: our reading next to the game's (`stellar.script.shadow`)

The first step toward Lua building the script itself: Lua reads the script files
(`stellar.script.source`: the files of a directory in load order, parsed with `pdxscript`, with
`inline_script` expanded and scripted definitions instantiated as the game does, see
[Templates](#templates-scripted-triggers-effects-and-values)), and `stellar.script.native` reads
back what the game compiled from them. The two are compared node by node: every native child must be
made, in order, by a statement of the same block (the same trigger or effect class, scope chain or
scripted name), with the same children; statements that make no node are counted by key, so that
the members of a trigger or effect (`limit`, `count`, `text` in `custom_tooltip`) are visible,
and a real keyword without a node shows up.

What the native side reads:

| | |
|---|---|
| children | `CTriggerCollectionBase::_Children` (`+0x78`) for collections (recognized by the vtable of that `CPdxArray<CTrigger *>`), the `CPdxArray<CEffect *>` every `CEffect` is (`+0x8`) |
| scope changes | `CContextTrigger` / `CContextEffect::_pTarget` (`+0xc8`), a `CEventTarget` chain: per link the token (`_Token` at `+0x68`), a dynamic name (`_DynamicFlag`), `_IsNullable` (the `?`), `_pNext`. Saved event targets (`event_target:x`, `event_target:x@root.owner`) have no token: their text is the game's `_TokenString`, which is the chain as written followed by the next links again |
| scripted calls | tag, arguments and the instantiated body (`CScriptedTrigger` `+0x98` / `+0x80` / `+0xd0`, `CScriptedEffect` `+0xe0` / `+0xc8` / `+0x118`) |
| if / else_if / else | `CIfTrigger::_pElse` (`+0x180`) and `CIfEffect::_pElse` (`+0x240`): the next else_if or else, another if object. `CIfEffect::_Else` (`+0x180`, an embedded `CEffect`) holds the old form, an `else` inside the if's own block. `CIfTrigger::_DisplayTrigger` (`+0xc0`) is the limit |
| source | `_FileLocationDesc` (`CTrigger +0x40`, `CEffect +0x28`): where the object was read, with the call chain for scripted and inline script content |

In Steam 4.5.2 (vanilla), comparing each scripted trigger and effect the game instantiated without
arguments with its definition:

| | definitions | compared | identical | nodes | mismatches | keywords without a node |
|---|---|---|---|---|---|---|
| scripted triggers | 1,684 | 1,423 | 1,423 | 9,167 | 0 | `text`, `fail_text` in `custom_tooltip` (members) |
| scripted effects | 1,687 | 1,249 | 1,248 | 16,742 | 1 | none |

The one difference was `country_defaulted_effect`, explained since: its unescaped
`[This.GetName]` in a `log` string starts a parameter block (see
[Templates](#templates-scripted-triggers-effects-and-values)). The definitions not compared are
only instantiated with arguments.

For developing this, `stellar.dev` runs `dev\run.lua` next to the DLL in the running game (when
`dev\enabled` exists): no restart to try a change. A long run holds the Lua lock; the turn tick
hook never waits for it (it skips Lua for that tick and counts it, `stellar.skipped_ticks()`), so
a loaded game keeps running.

### Templates: scripted triggers, effects and values

A scripted trigger, effect or script value is a template (`CMetaScriptTemplate`, shared by
`CScriptedTriggerTemplate`, `CScriptedEffectTemplate` and `CScriptValueTemplate`). Its `Read` keeps
the definition's text, and each call builds its own object from that text rewritten with the call's
arguments (`GenerateSource`, then a new reader on the result). From the disassembly of 4.5.2:

- **The kept text** is not the file's: `Read` writes the definition's tokens out again, each
  followed by a space, quoted strings quoted again, and newlines inserted so that every token stays
  on its line. Comments are gone; a token starting with `@` (inline math, `@var`) goes through
  `CReader::ParseAdvancedStatementWithVariables` first. The lexer makes `!` a token of its own, so
  `[[!NAME]` is kept as `[[ ! NAME]`.
- **Parameter blocks** (`ParseForMacrosArguments`, once at `Read`): `FindNonEscapedChar` finds the
  next `[` that does not follow a backslash (a plain `memchr`: quoted strings are not skipped), then
  the next `]` (end of the name), then the next `]` (end of the block). The name is the text from
  two characters after the `[` to the first `]`; if its second character is `!` the block is
  negated and the name starts three characters in (`[[ ! NAME]` -> `NAME`). The search for the next
  block starts after the end of this one: blocks do not nest, and any `[`, not only `[[`, starts
  one. A block without its closing `]` logs "Invalid macro entry" and ends the search.
- **Per call** (`ProcessSourceForMacros`, last block first): a block becomes its content (the text
  between the name's `]` and the closing `]`) when the call has an argument of that name (exact,
  case-sensitive) and the block is not negated, or has none and it is; otherwise it is removed,
  newlines and all, so the lines after it move up.
- **Arguments** (`ParseForArguments`, `ProcessSourceForArguments`): `$` pair up in order (not
  escaped by a backslash), whatever is between them; `|` inside the pair separates the default.
  Names match exactly (`$bonus$` is not `BONUS`), and an argument the call does not give, without
  a default, becomes the empty string (`GetArgumentValue` returns `CString::_NullString`).
- **Escapes**: finally `\[`, `\]`, `\|` and `\$` become `[`, `]`, `|` and `$`.

So a bracket in a string is a block: `log = "AI [This.GetName] defaulted ... [Root.GetName] in
[GetYear]"` in `country_defaulted_effect` loses `[This.GetName] defaulted ... [Root.GetName]`
(a block named "his.GetName") and `[GetYear]"` up to the next string's `[This.GetName]`, which
takes the `else` between them and its three lines. Vanilla otherwise writes `\[` in such strings.
`stellar.script.source` does the same (`source.template`, `source.generate`), on the file text with
comments blanked and inline math skipped, which gives the same result.

Inline scripts are not templates (`CreateInlineScriptReader`): the game replaces `$NAME$` with each
parameter in turn (`CString::ReplaceAll`) in the script's text and reads that; no blocks, no
defaults. Their content is located `file: events/x.txt:135(inline_script)
common/inline_scripts/y.txt line: 2` (a chain when inline scripts call others), where 135 is the
line where the `inline_script` statement ends: the `}` of `inline_script = { ... }`
(pdxscript blocks record it, `last`).

### Everything the game compiled (`shadow.everything`)

Every compiled object knows where it was read. The roots of the census, the objects no other object
points to (children, if chains, embedded limits and else blocks, scripted bodies:
`native:links`), are each compared with the statement at their place in our reading of that file,
whatever they belong to (events, buildings, jobs, decisions, ...). Members a trigger or effect keeps
outside its children (the `limit` of `count_*`, the trigger of a `switch` case) are roots of their
own and compared at their own place. What the comparison had to learn about the game's reading:

- a trigger can be named by a value: `trigger = num_districts` (complex trigger modifiers),
  `order_by = trigger:pop_amount`, `amount = x@root.trigger:fleet_integrity` inside a block (at the
  block's line);
- `switch` and `inverted_switch` make one trigger of the `trigger = x` kind per case, at the line of
  the switch;
- `hidden:owner = { }` is the scope change `owner` without its tooltip;
- the same key twice in a block (`init_effect` of a system initializer) is one block: the game
  appends the second;
- an event's `immediate` and option blocks are read without a location (their children have one);
- a block in a list (`{ name = x trigger = { } }` in ship_sizes) is read like any block;
- an event's `picture` reads a `picture = { ... }` inside its block as more of itself, and all its
  `trigger` blocks into one (at the first): vanilla puts inline scripts of whole picture blocks
  inside a picture block (`events/biogenesis_event_art`);
- a key an effect block does not know is read as a call of a scripted effect of that name (left
  unresolved if there is none): the docs' `stop_mission = { mission = x status = y }` makes two
  calls, `mission` and `status`;
- the identical code folding of the linker gives every `CPdxArray<T *>` one vtable: an array of
  tags (`trait_has_any_tag`) at the children's offset is not children; triggers and effects are
  recognized by being named.

Scripted calls are compared too. Each distinct body the game built (an instance) is our
`source.instantiate` of the definition with the call's arguments (`_Args`, a
`CPdxArray<pair<CString, CString>>`), compared with that body. The roots inside it (located
`common/scripted_effects/x.txt:12 @ scripted effect x at <the call's location>`) are compared
with the statements at their lines in that instance.

Script values are templates too (`CScriptValueTemplate`). Their content is located `file: script
value x at <the call's location> line: 5`, the line counted from the definition's first line (not
from the top of the file, as for scripted triggers and effects). The comparison groups those roots
by call, reads the definition with the call's arguments (`value:x|PARAM|1|` in the text of the
call's line; a call by the bare name has none, its parameters take their defaults) and compares
them with the statements at their lines.

Result, Steam 4.5.2 vanilla (1,318,141 compiled triggers, 424,716 effects; `dev\parity.txt`):

| | roots | compared | identical | nodes | mismatches |
|---|---|---|---|---|---|
| placed in a file (1,222 files: common/*, events, gfx, ...) | 111,616 | 111,616 | 111,616 | 354,984 | 0 |
| inline script content | 25,830 | 25,830 | 25,830 | 76,524 | 0 |
| scripted trigger instances (the bodies) | 114,353 | 114,353 | 114,353 | 403,125 | 0 |
| scripted effect instances (the bodies) | 13,852 | 13,852 | 13,852 | 135,438 | 0 |
| roots inside scripted triggers / effects | 52,893 | 52,893 | 52,893 | 133,777 | 0 |
| empty blocks every object of a database has | 222,568 | | | | |
| not compared yet | 38,669 | | | | |

Every compiled tree that was compared, 1,103,848 nodes, is identical.

Not compared yet:
- script values (22,941, and 15,226 more reached through scripted triggers and effects): their
  content is located `file: script value x at <the call's location> line: 5`;
- inline scripts inside scripted triggers and effects (502), located `file: scripted effect x at
  <the call's location>:193(inline_script) ...`;
- 348 effect blocks without a location whose first child has none either.

### Mods

`source.filesystem(game_dir, mods)` is the game's view of the files: the game directory, then the
mods in load order. A file of a later mod replaces the file with the same path, a mod's
`replace_path` hides the files before it in that directory, and a directory is read in name order
over all of them. `source.enabled_mods` reads the mods the launcher enabled
(`Documents/Paradox Interactive/Stellaris/dlc_load.json` and the `.mod` descriptors, which are
script too); `init.lua` and the comparison use them, so a modded game is compared with its mods.
The locations do not say which mod a file came from (`file: events/x.txt line: 3`): the path is
resolved like the game does.

Then:

- **Mods.** The comparison run on modded games.

Then Lua takes over building the script: the same trees, constructed in parallel from the Lua
reading instead of by the game's single-threaded reader.

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
