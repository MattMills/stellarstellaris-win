# Situations and first contact (4.5.2)

Two small content systems the game advances on its own: **situations** (`common/situations`, the
save's `situations = { situations = { } }`) and **first contact** (`common/first_contact`, the save's
`first_contacts = { contacts = { } }`). Reverse engineered statically from the GOG 4.5.2 build and its
PDB on hippo (`/root/fnm_tmp`: `annotate.py`, `pdbtype.py`, `full452.asm`), ported to
[`sim/lua/engine/situations.lua`](../sim/lua/engine/situations.lua) and
[`sim/lua/engine/first_contact.lua`](../sim/lua/engine/first_contact.lua). Addresses are GOG RVAs.
**[V]** marks what was read in the disassembly, **[I]** what is inferred (names, script files,
saves). The probes are in `H:\code_working\tmp_sitfc\`.

Numbers are the game's fixed point (`CFixedPoint`, int64, 1.0 = 100000): `a * b` is
`trunc(a * b / 100000)` (toward zero). Random draws are `CRandom::GetIntegerForMacro` (the global
stream, `E.rand` in the simulation); "line n" is the macro's line argument, which names the call
site.

## In short

- **Situations move once a month.** After the budget, a parallel pass computes each situation's
  monthly progress from its type's `monthly_progress` (a `CMeanTimeToHappen`: `base`, 0 when absent,
  then each `modifier` whose triggers hold applies its `add` / `subtract` / `mult` in order). In
  each country's monthly serial update, before its monthly pulse, every situation of the country gets
  `last_month_progress = that value`, `progress += it`, the stages and endings checked, and its
  type's `on_monthly` on_action fired. **[V]**
- **First contacts move every day**, in each country's daily serial update before its events:
  `days_left -= 1 + first_contact_speed_mult`; at 0 a roll (`last_roll`, 1-10), `days_left` back to
  80 (human owner) or 110 (AI), and the score `clues - difficulty - malus + bonus + last_roll`
  against 10: at or above, the stage's `stage_event` fires (its script advances the stage); below,
  the stage's `on_roll_failed` (vanilla: 1 or 2 clues by the score, a 1-in-20 random event). Without
  an envoy (`leader`) nothing moves. **[V]**
- **Checked over 180 days** (2210.01.01 -> the game's 2210.07.01, and 2211.07.01 -> 2212.01.01,
  section 3): the situations' monthly progress at day 0 is the save's `last_month_progress` (12 of
  12); after 180 days the progress differs only where the random pre-FTL events (breakthrough x2,
  setback x0.25 flags) went otherwise (2 or 3 of 12, by the stream).
  Every first contact whose envoy the AI did not change ends with the game's `days_left`;
  `last_roll`, `clues` and the stage events are dice. `situations` 154 -> 165 fields equal,
  `contacts` 3,387 -> 3,400. In the second pair a food deficit situation fails in the simulation
  because simscript's `resource_income_compare` reads the income where the game reads the balance
  (section 3).

## 1. Situations

### 1.1 The save and the class **[V]**

```
situations = { situations = { 0 = {
    country = 29  target = { type = none id = 0 }  type = "pre_ftl_tech_progress_situation"
    progress = 1360.125  last_month_progress = 0.3125  approach = "approach_revolt_do_nothing"
    stage_durations = { { start = 0 end = 1920 } }  stage_flags = { yes }  flags = { ... }  stage = 0
} } }
```

`CSituation` (`pdbtype.py`): `+0x38` `SSafePrivate` (its `+0x0` `_LatestMonthlyProgress`: the month's
value, computed in parallel, not saved), `+0x1d8` `_Target`, `+0x204` `_Country`, `+0x208`
`_pSituationType`, `+0x210` `_pApproach`, `+0x218` `_CurrentProgress` (`progress`), `+0x220`
`_LatestMonthlyProgress` (`last_month_progress`), `+0x2b8` `_Flags` (`flags`, timed flags counted down
daily like any object's), `+0x578` `_CurrentStageIndex` (`stage`), `+0x580` `_StageDurations`
(`stage_durations`, `{start, end}` pairs), `+0x638` `_ExecutedStageFlags` (`stage_flags`), `+0x660`
`_ToBeKilled` (`to_be_killed`), `+0x661` `_IsLocked` (`locked`).

`CSituationType`: `+0x118` `_OnComplete` (`on_progress_complete`), `+0x1d8` `_OnFail`, `+0x508`
`_MonthlyEvents` (`on_monthly`, a `COnActionList`), `+0x578` `_StartValue`, `+0x5b8`
`_UsesSectionWeights` (`total_progress`), `+0x5c0` the `monthly_progress` MTTH (base 0: the
constructor stores 0 at `+0x5d0`, `0x4e2ef4`), `+0x5f8` `_StageArray`, `+0xc80` `_IsPermanent`.

**start** = the first stage duration's `start` (the type's `start_value` when there are none),
**end** = the last one's `end`. `CSituation::HasFinished` (`0x61a4f0`): not permanent and progress
outside `[start, end)`.

### 1.2 The month

| step | game | what |
|---|---|---|
| after `CEconomicUnitManager::CalculateTablesOrUpdateBudget<0>` | `` `CGameState::MonthlyUpdate'::`21'::<lambda_1> `` (`0x262d20`), a parallel-for over the countries | per country, first 10 per-country objects fed from the month's pool (`(id + 5470 + i) % 1000`, not situations), then each of the country's situations (`CCountry +0x24b8` list): skipped when to be killed or locked; a non-permanent one only while `start <= progress < end`; `SSafePrivate._LatestMonthlyProgress = CSituation::GetMonthlyProgress` (`0x619a50`: 0 when locked, else `CMeanTimeToHappen::GetRawFactor` (`0x342930`) with the situation as scope). No draws **[V]** |
| `CCountry::MonthlyUpdateSerial` (`0x6f4b10`) | after the leaders' experience, the personality, decadence, loyalty: `CCountryEventManager::MonthlyUpdateSerial` (`0x6f548a` -> `0x804c90`), then the country's monthly on_action (`0x6f54b9`), then resource shortages (`HasResourceShortage` -> `StartSituation`: the deficit situations) | each of the country's situations: `CSituation::HandleMonthlyTickSerial` (`0x61c240`); those then marked to be killed destroyed (`CGameState::DestroySituation`); then the missions **[V]** |

`CMeanTimeToHappen::GetRawFactor`: the value starts at the base (`+0x10`) and each modifier (`+0x20`
array) applies itself to it in order (virtual `+0x10`) **[V]**; `add`, `subtract`, `mult`/`factor`
as the README of `common/situations` describes **[I]** (the modifier classes were not read).

`CSituation::HandleMonthlyTickSerial` **[V]**:

1. to be killed or locked: return;
2. finished: return (an error "Situation %s incorrectly ended" unless an event of it is open);
3. one draw (line 898): the random of the event scope (this = root = the situation);
4. with section weights: `RebuildStageDurations` and `HandleProgressChanged(true)` (not modelled);
5. `last_month_progress = SSafePrivate._LatestMonthlyProgress`;
6. not finished: `progress += it`, `HandleProgressChanged(true)`;
7. `UpdateTriggeredBlockedDescriptions` (the interface's alert);
8. not finished: `COnActionDatabase::PerformEvent(type +0x508, scope)`: the type's `on_monthly`
   (`events`, `random_events`; "technically an on_action called <the situation's key>").

`CSituation::HandleProgressChanged(draw)` (`0x61f910`) **[V]**: the progress clamped to
`[start - 1, end]` (`[start, end]` when permanent); `UpdateStage(draw)`; then, not permanent: below
`start`: one draw (line 1318) when `draw`, `on_fail`; at or above `end`: one draw (line 1324),
`on_progress_complete` (both run with the situation as scope; without `draw` the scope's random is a
hash of `year * 360 + day + the country`).

`CSituation::UpdateStage(draw)` (`0x61f060`) **[V]**: the new stage is the number of stage durations
whose `end` the progress has reached (the loop stops at the first it has not), at most the last;
when it differs from `stage` every stage in between is entered one by one, up or down (from none:
the new one directly). Entering stage i (`` `CSituation::UpdateStage'::`2'::<lambda_1> ``,
`0x61f190`): nothing past the type's stages; one draw (line 1205) when `draw`; `stage = i`; the
triggered owner and target modifiers updated when either stage has some, the country's modifier
invalidated; the blocked descriptions; `CSituationStage::OnEnter` (`on_enter`); then, when
`stage_flags[i]` is not set: set, one draw (line 1251), `CSituationStage::OnFirstEnter`
(`on_first_enter`).

### 1.3 In the simulation

`engine.situations` (wired in `systems.lua`, `monthly.countries_serial`): `monthly_progress` (all
situations, first in the phase: the game's parallel pass comes right after the budget and before the
AI's strategy pass) and `country_monthly(country)` (per country, before its
`on_monthly_pulse_country`). The monthly progress is computed in `CFixedPoint` (adds exact, products
truncated as `CFixedPoint::operator*`); the script values and triggers through `simscript.eval`.
`on_monthly` is registered with the script layer as an on_action named after the type and fired with
`host.on_action(type, "situation", id)`. The draws of lines 898, 1205, 1251, 1318 and 1324 are made on
the global stream; the on_action's `random_events` pick draws from it too (in the game it uses the
scope's random: one draw more per month and situation here) **[I]**.

Script the layer did not have, registered by `engine.situations` only where `simscript.eval` has
none: the `owner` link of a situation (its `country`), `target` (its `target = { type id }`),
`current_awareness_level` (a country's `awareness` against the `NGameplay` `AWARENESS_*_LIMIT`
bounds: unaware < 1 <= low < 30 <= medium < 60 <= high < 100 <= full), `situation_monthly_progress`
(the cached monthly value), `current_situation_approach`, and the effect `destroy_situation`
(marks it to be killed; destroyed after its country's tick).

Not modelled: creating situations (`start_situation`, the deficits `CCountry::MonthlyUpdateSerial`
starts on `HasResourceShortage`), approaches (the AI's `CalcAIWeight` choice, their resources), the
situations' modifiers and triggered modifiers (the modifier graph's), section weights
(`RebuildStageDurations`: the save's durations are kept and counted), `UpdateTriggeredBlockedDescriptions`,
the `dead_situation` store.

## 2. First contact

### 2.1 The save and the class **[V]**

```
first_contacts = { contacts = { 17 = {
    owner = 16777219  country = 16777224  name = { ... }  location = 38  leader = 167772180
    date = "2207.06.20"  last_roll = 2  days_left = 9.7  difficulty = 7  clues = 1
    stage = "default_stage_2"  status = in_progress  events = { ... }  completed = { { date stage } }
} } }
country = { 6 = { first_contact = { contacts = { 19 } } } }
```

`CFirstContact` (808 bytes): `+0x28` `_GalacticObject` (`location`), `+0x2c` `_Owner`, `+0x30`
`_ContactCountry` (`country`), `+0x34` `_AssignedEnvoy` (`leader`), `+0x38` `_pStage` (`stage`),
`+0x40` `_StartDate`, `+0x48` `_nTotalClues` (`clues`), `+0x4c` `_nNewlyAddedClues` (not saved),
`+0x50` `_nLastDieRoll` (`last_roll`), `+0x54` `_nDifficulty`, `+0x58` `_vDaysLeftUntilRoll`
(`days_left`, CFixedPoint), `+0xb8` `_PendingEvent` (`event`), `+0x278` `_Completed`
(`completed`), `+0x290` `_Flags`, `+0x308` `_FirstContactEvents` (`events`), `+0x320` `_Status`
(`EStatus`: InProgress 0, Locked 1, Finished 2, Aborted 3; `in_progress`, `locked`, `finished`,
`aborted`).

Defines (`common/defines` `NGameplay`): `FIRST_CONTACT_DICE_ROLL_MIN` 1, `_MAX` 10,
`FIRST_CONTACT_DISCOVERY_SCORE` 10, `FIRST_CONTACT_DISCOVERY_DAYS` 80, `_DAYS_AI` 110,
`FIRST_CONTACT_INTEL_TARGET` 10, `FIRST_CONTACT_LOWER_INSIGHT_SCORE` 0 / `_HIGHER_` 5,
`FIRST_CONTACT_LOWER_INSIGHT_REWARD` 1 / `_HIGHER_` 2.

### 2.2 The day **[V]**

`CCountry::DailyUpdateSerial` -> `CCountry::UpdateContacts` -> `CFirstContactsData::DailyUpdate`
(`0x8d8790`), over the country's `first_contact.contacts` **from the last**: a contact whose owner or
contact country no longer exists is taken out of the list (the last id moved into its place) and
destroyed, with a message (`MESSAGE_FIRST_CONTACT_ABORTED`) when it was in progress; a living one not
finished or aborted gets `CFirstContact::DailyUpdateSerial` (`0x8db580`):

1. locked: return; no envoy (the leader reference dead) : return; finished or aborted: return;
2. the owner's intel on the contact country (`CIntelManager::GetIntelData`, the save's
   `intel_manager = { intel = { { <country> { intel = x } } } }`) `>= FIRST_CONTACT_INTEL_TARGET`:
   `Finish`, return;
3. `_nNewlyAddedClues = 0`;
4. `days_left -= CalcDiscoverySpeed` (`0x8dd380`) `= 1 + v(first_contact_speed_mult)` of the owner
   (modifier 408); while `days_left > 0`: return;
5. `days_left = FIRST_CONTACT_DISCOVERY_DAYS` when the owner has human players
   (`CCountry::_HumanIds`, `+0x3138`) and no cheat flag, else `FIRST_CONTACT_DISCOVERY_DAYS_AI`;
6. one draw x (line 682); `last_roll = (noise(noise(x, 0x5EA6A49F), 0) & 0x7FFFFFFF) % (MAX - MIN + 1)
   + MIN`, where `noise` is CRandom's hash (docs/simulation.md section 3) without its final mask;
7. `MAX - MIN + 1` more draws (`CRandom::GetIntegersForMacro`, line 688; the values unused);
8. `CalcCurrentDiscoveryScore` (`0x8dd1c0`) `= clues - (difficulty + malus) + bonus + last_roll`:
   - bonus (`CalcDiscoveryBonus`, `0x8ddcb0`, the owner's modifiers 385, 386, 409) =
     `int(intel_decryption_add * m(intel_decryption_mult)) + int(first_contact_clues_add)`,
   - malus (`CalcTargetDiscoveryMalus`, `0x8dd9d0`, the contact country's 383, 384, 410) =
     `int(intel_encryption_add * m(intel_encryption_mult))` when its country type has the
     `Playable` flag (`ECountryTypeFlags` 2), `+ int(first_contact_defense_add)`;
   - `m(x) = max(the definition's minimum, 1 + x)` (0 here, as in colonies.md), `int` truncates;
     modifier numbers are their line in `script_documentation/modifiers.log` minus 8 (408
     `first_contact_speed_mult`, 409 `first_contact_clues_add`, 385 `intel_decryption_add`);
9. `score >= FIRST_CONTACT_DISCOVERY_SCORE`: one draw r (line 695), `FireStageEvent(r)`; else one
   draw r (line 699), `HandleRollFailed(r)`.

`FireStageEvent` (`0x8dc4e0` -> `0x8dc0c0`): three draws (line 767 and two more) for the scopes'
randoms (this = root = the first contact, from = the contact country); each `stage_event`'s
`event_weight` (a `CMeanTimeToHappen`, base 0) evaluated; one picked by
`GetWeightedRandomInternal<CFixedPoint>` (`0x1b4ad80`: `r % total` of the positive weights when
`total <= 2^31 - 1`, the first whose running sum exceeds it) and fired
(`CEventManager::TriggerEvent`); none: an error logged. The stage itself changes only through the
event's script (`set_first_contact_stage`).

`HandleRollFailed` (`0x8db810`): the stage's `on_roll_failed` effect with the same scopes. In
vanilla, `standard_first_contact_on_roll_failed`: `add_stage_clues = higher_insight_reward` (2) when
`is_site_current_stage_score >= higher_insight_score` (5), else `lower_insight_reward` (1) when
`>= lower_insight_score` (0); then a `random_list` 19 : 1 for a random event of the stage's set.

### 2.3 What the scripts do with it **[V]**

| script | game | what |
|---|---|---|
| `set_first_contact_stage = x` | `CSetFirstContactStageEffect` -> `CFirstContact::SetCurrentStage` (`0x8d9400`) | the old stage appended to `completed` with today; the stage set; one draw (line 311): `difficulty = stage min + (noise(noise(x, 0x5EA6A49F), 0) & 0x7FFFFFFF) % (range + 1)` (vanilla stages have one value); the pending event reset; `clues = 0` |
| `add_stage_clues = n` | `CAddStageCluesEffect` (`0x17f8130`) | `n = max(n, -clues)`; newly added += n; `clues += n` |
| `set_site_progress_locked = yes/no` | `0x17b6370` | unless finished or aborted: status locked / in progress |
| `finish_first_contact = yes` | `CFirstContactFinishEffect` -> `CFirstContact::Finish` (`0x8dcd60`) | a message; `on_first_contact_finished` (this = the first contact, from = the contact country); the envoy released (`CLeader::_Location` reset: the save drops its `location`, its assignment cooldown 0); `CCountry::EstablishCommunications(owner, contact)`; status finished |
| `is_site_current_stage_score` | `CIsArchaeologicalStageCurrentScoreTrigger` (`0x1a0f930`) | the score of 2.2 step 8 (with the die); `lower_insight_score` / `higher_insight_score` read as the defines (`Assign`, `0x1a0f8e0`) |
| `is_current_first_contact_stage = x` | `0x1a1c680` | the stage's key |

### 2.4 In the simulation

`engine.first_contact` (wired in `systems.lua`, `daily.countries_serial`): `country_daily(country)`
for each country before its daily events, as the game's `UpdateContacts` comes before
`CCountryEventManager::DailyUpdateSerial`. `days_left` in CFixedPoint; the roll's hash in Lua (`noise`
checked against `rng.rs` on 1,000 inputs); every draw of 2.2 and 2.3 on the global stream; the
stage event fired through `simscript.events.fire`.

Script registered by `engine.first_contact` where `simscript.eval` has none: the links `owner`,
`contact_country`, `leader` (the envoy), `solar_system` (`location`) and `reverse_first_contact` of a
first contact; the list `active_first_contact` (a country's contacts in progress or locked: `any_`,
`every_`, `random_`); the triggers `is_site_current_stage_score`, `..._no_die`,
`is_current_stage_clues`, `is_current_first_contact_stage`, `has_active_first_contact_with`; the
effects `add_stage_clues`, `set_first_contact_stage`, `set_site_progress_locked`,
`finish_first_contact`.

Not modelled: creating first contacts (`CFirstContactManager::CreateContact` from
`CCountry::ContactInternal`: fleets meeting, intel), the intel itself (the save's value is read, it
does not grow), the AI's envoy assignments (`leader` changes in the game's saves), the pending event
and the player's choice (the AI stand-in answers at once), `EstablishCommunications` beyond dropping
the relations' `pre_communications_name` (intel, `communications`, the on_actions, the other
country's contacts), the assignment cooldown.

## 3. Checks

`examples/diff` over 180 days, before (the same tree without the two modules) and after, fields
equal / differ:

| | 2210.01.01 -> 2210.07.01 before | after | 2211.07.01 -> 2212.01.01 before | after |
|---|---|---|---|---|
| `situations` | 154 / 16 | 165 / 11 | 159 / 25 | 146 / 18 (1 only in the game) |
| `contacts` | 3,387 / 160 | 3,400 / 149 | 3,693 / 300 | 3,695 / 304 |
| all stores | 717,202 / 16,927 | 717,219 / 16,918 | 718,509 / 18,434 | 718,444 / 18,487 |

(sim-engine after 2ec285a: the generator starts from the save's seed and position.) The totals move
little: the new draws (a few hundred over 180 days) shift the global stream, and
the other systems' random outcomes (ethics, pops, events) move with it, about as many fields worse
as these two stores gain.

Situations at day 0 (`tmp_sitfc/probe_sit.lua`): the monthly progress equals the save's
`last_month_progress` for all 12 situations of 2210.01.01 (10 pre-FTL, 2 fallen empires) and for 11
of 13 of 2211.07.01: situation 7 computes 0.5625 against the saved 2.25, exactly the x0.25 of the
`technological_setback` flag it carries, set after its last tick by that month's `on_monthly` event
**[I]**; the food deficit is the trigger below. After 180
days the differences left are the `preftl` events' random flags (`technological_breakthrough` x2,
`technological_setback` x0.25: 2 situations in the first pair, 5 in the second), and in the second
pair the food deficit situation: the simulation fails it (progress below 0 in 4 months, `on_fail`,
destroyed) where the game takes -1 a month. Its `monthly_progress` subtracts 5 when
`resource_income_compare = { resource = food value >= 0 }`; `simscript.eval` compares the month's
gross income, but `SResourceIncomeCompare::GetResourceAmount` (`0x19ae6e0`) reads the country's
`+0x1f90` = `_Budget` (`+0x1c80`) `._CurrentMonth` (`+0x10`) `._Total` (`+0x218`) `._SummedBalance`
(`+0xe8`): the **balance**, income minus expenses (with a category: that block's `_Balance`)
**[V]**. With the balance the probe gives -1, the game's (`tmp_sitfc/probe_deficit.lua`); the
trigger is simscript's, left as it is here.

First contacts (`tmp_sitfc/probe_cmp.lua`, every field after `run 180`): in the first pair every
contact in progress whose envoy the AI kept ends with the game's `days_left` (the speed and the
80 / 110 days exact); the ones left are the AI's (two given an envoy in the game, two had theirs
replaced, which paused them about a week) and contact 15, which the game finished on a lucky roll.
A stage change the simulation made on the game's own day (contact 20, 2210.01.29) gets the game's
`completed` entry, difficulty and stage. `last_roll`, `clues` (by the score of each failed roll),
the stage events and their `completed` entries follow the dice: compare them as distributions. The
die (`noise(noise(x, 0x5EA6A49F), 0)`) is checked against `rng.rs` (`tmp_sitfc/probe_fc.lua`: 1,000
of 1,000).

The leaders' `location.*` differences (11) stay: they are envoys the AI moved or a contact the game
finished and the simulation did not.
