# The game's script documentation (4.5.2)

What the game writes about its own script engine at every start, what it gets right and wrong,
and how the coverage mod (`stellar-lua-pdxscript`, `tools/docs_mod/make_docs_mod.lua`) uses every
keyword it lists. The files are the Steam 4.5.2 dump of 2026-10-12; the writers were named in the
GOG 4.5.2 build and its PDB. Addresses are GOG RVAs (image base `0x140000000`). **[V]** marks what
was verified (in the disassembly, the PDB names, the files or the vanilla script), **[I]** what is
inferred. The mod has not been loaded by the game yet: what it says about the game's reading of a
keyword is **[I]** unless noted.

The engine side (token ids, the trigger and effect databases, how an entry creates its object) is
in [script_engine.md](script_engine.md); `modifiers.log` is described in
[modifiers.md](modifiers.md#definitions); when the files are written in the load is in
[loading.md](loading.md).

## Where and when

`Documents/Paradox Interactive/Stellaris/logs/script_documentation/`: `triggers.log`,
`effects.log`, `scopes.log`, `localizations.log`, `modifiers.log`. They are log channels: every
log of the game, these included, is emptied when the game starts and written while it loads
**[V]** (seen: all emptied at 07:58:28, the five documentation files written at 08:00:01, with
the same content as the previous run's). Anything that reads them must copy them first if the
game may start meanwhile; the coverage mod's snapshot is `C:\lfm\docs-mod\script_documentation\`.

Each file starts with the log line's prefix and the section header, e.g.
`[07:12:53][game_application.cpp:1419]: ` then `== TRIGGER DOCUMENTATION ==` **[V]** (effects
`:1422`, scopes `:1434`, localizations `:1454`, modifiers `[modifier.cpp:2274]`), and the first
four end with a line of `=`.

## Who writes them

| file | writer | **[V]** |
|---|---|---|
| all but modifiers.log | `CGameApplication::PrintScriptingDocumentation` (`0x1bb5d0`), near the end of `InitGame` (41.0 s in [loading.md](loading.md)'s timeline) | four sections, each `Log` (`0x15c690`, the file's channel) of a header string, the generator, then `"\n================="` (`0x2327588`) |
| triggers.log | `CTriggerDatabase::GenerateDocumentation` (`0x3448e0`), after `CTriggerDatabase::CreateInstance` (`0x344060`) | header `"\n== TRIGGER DOCUMENTATION ==\n"` (`0x23275c0`) |
| effects.log | `CEffectDatabase::GenerateDocumentation` (`0x3a8ba0`), after `operator new` + `CEffectDatabase::CEffectDatabase` (`0x3a85c0`) | header at `0x23275a0` |
| scopes.log | `CEventTarget::GenerateEventTargetDocumentation` (`0x3591a0`); `CEventTarget::GetTargetDocumentation` (`0x359aa0`) per link **[I]** | header and introduction at `0x2327600` |
| localizations.log | `CGameText::GenerateDocumentation` (`0x5e85e0`) on a `CGameText` made for it (`0x5e41d0`) | header at `0x2327720` |
| modifiers.log | `CModifier::LogDefinitions` (`0x36d980`), see [modifiers.md](modifiers.md) | |
| list iterators | `CEveryInScriptedListEffect::GenerateDocumentation` (`0x1811bb0`), `CRandomInScriptedListEffect::` (`0x1811f10`), `COrderedScriptedListEffect::` (`0x1812230`) | names; the `any_`/`count_` triggers have their own **[I]** |

`CTriggerDatabase::GenerateDocumentation` builds each entry from the name, `" - "` (`0x233aefc`),
the description and the syntax text, then `"Supported Scopes:"` (`0x235cec8`) followed by `" all"`
(`0x235cec0`) or, per scope, `" "` and `NEventScope::GetScopeName` (`0x38dea0`) **[V]**. Its loop
makes an indirect call through vtable slot 1 **[V]**, an entry's `Create`
([script_engine.md](script_engine.md)) **[I]**: the scope list would then be the created
object's own `GetSupportedScopes` mask, the one the game checks a trigger's scope with **[I]**,
which makes "Supported Scopes" the most reliable part of an entry; the description and syntax
are hand-written text. The list iterators (`every_x`, `random_x`, `ordered_x`, `any_x`,
`count_x`) get their text from one template per kind, with the list's name put in **[I]**: the 512
iterator entries at the end of the two files (206 triggers, 306 effects) read alike, and an error
in a list's description shows in all its forms.

`OnExecute_PrintTriggerDocumentation` (`0xeb2e20`) is a console command handler, and the string
`"effect_docs"` (`0x23d3c60`) a command name **[V names]**: the documentation can also be printed
from the console **[I]**.

## The files

### triggers.log, effects.log, scopes.log

One paragraph per keyword, starting after a blank line **[V]**:

```
name - description
<syntax lines, free text, optional; may contain blank lines>
Supported Scopes: country ship fleet          (or "all")
Output Scope: planet                          (scopes.log only)
```

| file | entries | without a syntax line | syntax that does not start with the keyword |
|---|---|---|---|
| triggers.log | 1,098 | 39 | 27 (2 are else / else_if, whose example starts with the `if`) |
| effects.log | 1,080 | 24 | 40 (2 are else / else_if) |
| scopes.log | 99, after an introduction paragraph | all | |

No name is written twice in any file **[V]**. The trigger and effect names are exactly the
databases' entries ([script_engine.md](script_engine.md): 1,098 and 1,080 registered, all
documented); 9 names are both a trigger and an effect (`if`, `else_if`, `else`, `switch`,
`inverted_switch`, `custom_tooltip`, `closest_system`, `log`, `debug_break`). scopes.log's 99
links are all tokens. Their outputs
are concrete scopes but for 11 `various` (`from`, `root`, `prev`, `this`, `fromfrom`..., `target`).

The scope names in "Supported Scopes" (40 and `all`) **[V]**: country, ship, planet, colony,
galactic_object, fleet, pop_group, leader, pop, starbase, species, sector, megastructure,
federation, archaeological_site, espionage_operation, army, spy_network, astral_rift,
pop_faction, war, first_contact, agreement, deposit, situation, bypass, ambient_object,
ship_growth_stage, no_scope, espionage_asset, cosmic_storm, debris, job, mission, design,
dlc_recommendation, cosmic_storm_influence_field, exhibit, trait, galactic_community. Three are
special: `planet ship colony` (291 entries) is a colony carrier (a planet, or a nomad's ship) and
its colony; `pop` (125 entries) names an object 4.x no longer has (see the gaps);
`dlc_recommendation` is only the empire designer's DLC hints.

The syntax text uses a loose placeholder vocabulary **[V]**: `<triggers>` (422 times), `<effects>`
(326), `<key>` (235), `<variable>` (161), `<target>` (122), `<int>`, `<string>`, `<yes/no>`;
type names (`<federation law>`, `<starbase module>`, `<relic_key>` ...); choices `a/b/c` and
`<a/b(default)>`; any comparison as `>=<`, `><=`, `<=>`, `< = >` or `<comparator>`; bare stand-ins
(`x`, `nDays`, `int`, `float`); comments as `(optional)`, `(default: no)`, `# ...`, `[...]` and
whole prose lines between the block's lines; alternative forms with `OR`, `or`, `|`, or one
example per line.

### localizations.log

A header (escaping `[[`, `$@var$` for scripted variables, and the unscoped commands GetDate,
GetMidGameDate, GetLateGameDate, GetYear, LastKilledCountryName), then 44 sections `--Name--`,
each with `Promotions:` (commands that lead to another object: `[Root.Capital.GetName]`) and
`Properties` (text: `[Root.GetName]`), one command per line indented by a space **[V]**. 333
listed commands and the 5 unscoped ones. Sections include objects only special localisation has:
`Timeline Event` (promotions `EVENT_TARGET_0` to `_9`), 13 `Dead ...` objects, `Patron Relation`,
`Specimen`. Scripted localisation (`common/scripted_loc`) is not listed.

### modifiers.log

`- <name>, Category: <labels>`, 45,583 types in index order, none twice **[V]**. Format, writer
and categories: [modifiers.md](modifiers.md#definitions).

## Gaps and errors

Found while writing a use of every keyword from its example **[V]** against the files and the
vanilla script (the game's reading of the fixed uses is **[I]** until the mod is loaded):

| what | examples |
|---|---|
| no example at all | `and`, `nand`, `nor`, `not`, `or`, the effect `log`, `tooltip`, `observer_event`, `spawn_planet`, `fallen_empire_strength_scale`, the seven `num_cosmic_storm_*_setting`, `cosmic_storm_system_influence` |
| the example names another keyword | `leader_years_of_service` (`years_of_service`), `num_owned_planets` (`num_owned_colonies`), `governors_skill_in_system` (`has_base_skill`), `is_unemployed` (`has_unemployment_job_category`), `is_influence_center` (`has_owner`), `is_last_acquired_specimen`, `num_ascension_perk_slots`, `delete_fleet_naval_cap` (`delete_ship_naval_cap`), `force_remove_civic_by_index`, `link_to` (`set_linked_to`), `merge_species` (`integrate_species`), `add_resource_from_debris` (`add_resource`), `set_trade_conversions`, `set_federation_succession_term`, `cosmic_storm_event` (`storm_event`), `cosmic_storm_influence_field_event` (`storm_influence_event`); typos `ppropose_resolution`, `is_years_since_community_formationn`; the `*_trait_of_species` and `*_trait_available_for_species` iterators without their prefix |
| the example is the block's lines without the block | `create_cosmic_storm` (and its `storm_start_position` is `cosmic_storm_start_position` in vanilla), `create_cosmic_storm_influence_field` (`radius`), `destroy_cosmic_storm_influence_field` (`center`), `start_storm_area_placing`, `set_cosmic_storm` (vanilla: `set_cosmic_storm = { cosmic_storm = prev }`), `spawn_custom_debris` |
| an operator without its value | `stored_physics_points`, `stored_society_points`, `stored_engineering_points` (the name alone) |
| syntax that does not parse | `num_leader_traits` (a key without `=`, an unclosed `<`, a `#` comment swallowing the rest), `ethos = <random / { ethic = <key> }` without its `>` (`create_rebels`, `create_colony`, `create_country`), `count_species_traits` (`cost < = > <trait cost> \| count < 2`), `federation_experience >=< 40 );`, prose inside blocks (`create_leader`, `modify_species`, `rename_species`, `change_species_characteristics`) |
| stand-in values that exist nowhere | `my_test_civic_1`, `tr_my_santa_claus_tradition`, `ap_my_ascension_perk`, `my_situation_type`, `special_project_name`, `my_contract`, `tradition_example`, `bypass_type`, `myfirstsoundeffect`, `COUNCIL_POS_KEY`, `COUNCIL_POSITION_TAG`, `RULER_TITLE_MALE`, `event.1`; stand-in keys `some_flag_1 = yes` (`set_faction_properties`: vanilla writes `needs_border_access`), `except = { tech_1 tech_2 }`, `NAME_a` |
| a parameter given two ways | `check_economic_production_modifier_for_job` (`resource` a word and a block), `create_ship` (`design` and `random_existing_design`), `spawn_megastructure` (`planet` and `coords_from`), `create_pop_group` (`pop_group` and `species`) |
| wrong descriptions | `count_archaeological_site` has `count_federation_ally`'s text and example; `last_created_system` "Scopes to the last fleet"; `any_system_in_cosmic_storm_influence_field` "influence fields owned by a country"; `is_influence_center` "Checks if the planet is colonized" |
| deprecated (the docs say so) | `ethos` (use `pop_ethics_divergence`), `num_owned_planets` (use `num_owned_colonies`), and the `owned_planet` iterators (`any_`, `count_`, `every_`, `random_`, `ordered_`; use `owned_colony`) |
| a scope nothing reaches | `pop`: no event type, link or iterator leads to one; `has_pop_flag`, `set_pop_flag`, `remove_pop_flag`, `set_timed_pop_flag` support nothing else. Vanilla's only `pop_event` is commented out (`events/pop_events.txt`), and the exe has the string once. `dlc_recommendation` alone: `name_list_category`. `galactic_community` is never the only scope |
| events of a type vanilla never defines | `cosmic_storm_event`, `cosmic_storm_influence_field_event` fire events of the types the exe names `storm_event` and `storm_influence_event`; no vanilla file defines one |
| only in one context (by the description) | `text`, `success_text`, `fail_text` (an event's `desc = { trigger = { } }`), `has_war_goal` (diplomatic phrases), `has_automation_setting` (automation targeting), `is_offer_terms_actual`, `can_afford_special_offer`, `get_trade_data`, `make_special_trade` (`ai_trade_facility` script), `force_show_diplomacy`, `force_show_espionage` (custom diplomacy events) |
| debug only | `debug_break` (trigger and effect) |
| names in another case | `and`, `or`, `not`, `nor`, `nand` are documented in lower case; vanilla writes `AND`, `OR` ... (and `not`, `or`, `nor` lower case in a few places): the names are read without regard to case **[I]** |
| the game reads it otherwise | `stop_mission = { mission = x status = y }` is read as two calls of scripted effects named `mission` and `status` **[V]** (the shadow comparison, [script_engine.md](script_engine.md)): the documented block is not stop_mission's parameters |

Of the documented keywords, a text scan of vanilla `common/` and `events/` finds 821 of the 1,098
triggers and 812 of the 1,080 effects written in a trigger or effect block **[I]** (the context is
guessed from the enclosing keys); the census of compiled objects counts 884 and 802 keywords used
([script_engine.md](script_engine.md)). About a quarter of the documented keywords are therefore
compiled by no vanilla file: the coverage mod is for those.

## The coverage mod

`tools/docs_mod/make_docs_mod.lua` in stellar-lua-pdxscript (`luajit make_docs_mod.lua <docs dir>
<game dir> <out dir>`, about 6 s) writes a mod that uses every documented trigger, effect, scope
link, modifier and localisation command once, where the game accepts it, and `manifest.tsv` with
the file and line of each (or why it was skipped). Output: `C:\lfm\docs-mod\stellar_docs_coverage\`
and `stellar_docs_coverage.mod`, not installed. Nothing in it fires: every event is
`is_triggered_only` with `trigger = { always = no }`, nothing calls them, nothing applies the
static modifiers.

How a use is made, the first way that works:
1. an override written by hand in the script (64), for the gaps above;
2. the documentation's example, its placeholders filled with what vanilla writes for the same
   keyword and parameter (`vanilla.values[kind][name][path]`), an object of the kind the
   placeholder names (`<federation law>` -> the first of `common/federation_laws` that vanilla
   also refers to), the first of a listed choice, or the mod's own names (`sdc_flag`, `sdc_var`,
   `sdc_text`, `from` for a target, `always = yes` for `<triggers>`, `log = "sdc"` for
   `<effects>`); every word the example itself names must be known to vanilla (a value written
   after the same key, an object of `common/`, a scope chain of documented links) or be a choice
   the example lists;
3. the shortest vanilla use of the keyword in a block of the right kind.

Where each keyword goes (by the first of its supported scopes in a fixed preference order):

| scope | how it is reached |
|---|---|
| country, planet, colony, fleet, ship, pop_group, leader, galactic_object, starbase, pop_faction, first_contact, situation, espionage_operation, astral_rift, bypass, agreement | events of that type (`country_event`, ..., `system_event`, ..., `agreement_event`) |
| species, federation, no_scope | from a country event, the link of that name |
| trait | `species = { any_trait_of_species = { } }` (`every_` in effects) |
| war, army, megastructure, debris, cosmic_storm, mission, exhibit | from a country event, `any_war` / `every_war` and the like |
| sector, job | from a colony event: the link `sector`, `any_owned_pop_job` |
| deposit, archaeological_site | from a planet event: the links `last_added_deposit`, `archaeological_site` |
| ambient_object, cosmic_storm_influence_field | from a system event: `any_system_ambient_object`, the link `storm_influence_field` |
| spy_network, espionage_asset | from an espionage operation event: the link `spynetwork`, `any_espionage_asset` |
| design, ship_growth_stage | from a ship event: the links of those names |

The generator checks each step against the documentation (the link or iterator exists and
accepts the scope it starts from). Triggers go in the events' `trigger` blocks, effects in
`immediate`; `text`, `success_text` and `fail_text` in the desc trigger of `sdc.1`; `X_event`
effects refer to the mod's own events (`sdc.1` to `sdc.18`, one per event type, and a
`carrier_event` and an `observer_event`). Every link is used as a scope change, with 12 dotted
chains. Every modifier is in one of 46 static modifiers (one per `Category:` string), at 0.01.
Every localisation command has a key of its own, all shown by `sdc.1`'s desc; objects other
than the country are reached by event targets saved in its `immediate`
(`[sdc_loc_war.MainAttacker.GetName]`); a promotion is followed by `GetName` (`SpyNetwork` by
`Owner.GetName`). Scripted triggers and effects with `$PARAM$`, `$PARAM|default$`, `[[PARAM]` and
`[[!PARAM]` blocks, `optimize_memory` and inline math, and the control flow in vanilla's own forms
(`AND`/`OR`/`NOT`/`NOR`/`NAND`, if/else_if/else chains, `while`, `random_list` with modifiers,
`switch`), are there too.

Result **[V]**: triggers 1,091 of 1,098 placed (1,034 from the example, 32 overrides, 25 from
vanilla), effects 1,071 of 1,080 (999, 32, 40), links 99 of 99, modifiers 45,583 of 45,583,
localisation commands 294 of 338 (the dead objects, timeline events, specimens and patron
relations skipped). Skipped triggers and effects: 7 deprecated, 4 pop-only, 2 debug, 1
dlc_recommendation-only, 2 storm event effects. Every file parses with `pdxscript` without a
warning, every manifest line holds its keyword, and a rerun writes the same files.

What to check in `error.log` once the mod is loaded **[I]**: the documented parameters vanilla
never writes (`num_claims_on_system = { Target = FROM Count >= 1 }` with its capitals,
`num_leader_traits`, `num_buildings`, `create_ship`, `create_leader`, `modify_species`,
`set_planet_entity` with `atmosphere_color = hsv { }`); the context-only keywords above in plain
events; the uses written by analogy (`stored_*_points > 100`, the storm settings `> 0`,
`set_terraform_progress = 0.5`, the storm effects wrapped as blocks); `count = all` in the 57
`count_` iterators vanilla has no example of; and `stop_mission`, whose documented form the game
reads as two scripted effect calls.
