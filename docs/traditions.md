# Traditions and ascension perks (4.5.2): cost, adoption, the AI's choice

What the game does when a country adopts a tradition or an ascension perk, and how the AI picks one,
read off the GOG 4.5.2 build and its PDB on hippo (`/root/fnm_tmp`: `annotate.py`, `pdbtype.py`).
Addresses are GOG RVAs. **[V]** marks what was read in the disassembly, **[I]** what is inferred.
Fixed point: `CFixedPoint` is int64 with 1.0 = 100000. The Lua is `sim/lua/engine/traditions.lua`
(game logic) and `sim/lua/engine/ai/traditions.lua` (the AI); context in [ai.md](ai.md) (the AI's
structure, its random generators) and [simulation.md](simulation.md) section 6 (the engine).

## In short

- **Cost** (`CTraditionType::CalcCost`, `0x4c0f00`) depends on the country only, not on the
  tradition: `(300 + (8 n)^1.8) * (1 + empire size penalty) * max(1 + tradition_cost_mult, 0) *
  galaxy.traditions` unity, with `n` every tradition the country has (adoptions and finishers
  included). Perks cost nothing.
- **Adoption** (`CCountryActivateTraditionCommand::Execute`, `0x6c6ae0`): the cost is removed from
  the stockpile, the tradition appended (its category too when new), `last_picked_tradition` set;
  then `OnEnabled`: one draw of the global generator, the `on_enabled` effect, the on_action
  `on_tradition_picked`, and the category's finisher activated for free once every other tradition
  of the category is there.
- **The AI** (`CAIInteriorMinister::HandleTraditions`, `0xbc3250`, on the AI's month when the country
  type has `ai = { traditions = yes }`): if the AI's `traditions` budget (the whole unity stockpile,
  see below) covers the cost, a weighted random pick among the traditions of the adopted
  categories whose `possible` holds (or, once every adopted category is complete, among the
  adoptions of the potential new categories), with the scripts' `ai_weight`s, drawn from the AI's
  unsynced generator. So **when** a country adopts is deterministic (its first AI month with
  stockpile >= cost) and **which** tradition is random.
- **Ascension perks** (`HandleAscensionPerks`, `0xbc3880`), when the type has `ascension_perks = yes`
  and a slot is free: the same kind of weighted pick among the perks that can be activated.
- **Check** (2210.01.01 -> 2210.07.01): the two adoptions the game made (16777219: 4 -> 5, 49: 2 ->
  3) are the two the simulation makes, no other country adopts and no perks; the unity stockpiles
  explained go from 47.6% to 81.1%. The simulation adopts one AI month earlier than the game
  probably did (its unity income for these two countries is a little higher than the game's); the
  traditions picked differ (random: 50% and 17% chances in the game's picks).

## 1. Data

### The save (`country = { ... }`) **[V]** (`CCountry::WriteTraditions`, `0x74c5d0`)

```
tradition_categories = { "tradition_supremacy" }
traditions = { "tr_supremacy_adopt" "tr_supremacy_master_shipwrights" ... }
ascension_perks = { "ap_x" }                     (CPdxArray of perks, written when not empty [I])
last_picked_tradition = "tr_supremacy_fleet_logistical_corps"
modules = { standard_economy_module = { resources = { unity = 761.79443 } } }    (the stockpile)
empire_size = 104                                (CCountry::_nCachedEmpireSize, an int)
galaxy = { ... traditions = 1 ... }              (top level: the tradition cost slider)
```

### Layouts **[V]** (`pdbtype.py`)

| object | offset | what |
|---|---|---|
| `CCountry` | `+0x2f78` | `_nCachedEmpireSize` (int) |
| | `+0x2fd8` | `_pLastPickedTradition` |
| | `+0x2fe0` | `_TraditionCategories` (`CPdxArray<CTraditionCategory const*>`: data `+8`, count `+0x14`) |
| | `+0x2ff8` | `_Traditions` (data `+0x3000`, count `+0x300c`) |
| | `+0x3010` | `_AscensionPerks` (count `+0x3024`) |
| | `+0x31a0` | the country's `CModifier` (ids `+0x10`, count `+0x1c`, values `+0x38`) |
| | `+0x2a80` | the economy module (`CEconomyCountryModule`; vfunc `+176` affordability) |
| `CTraditionType` | `+8` | the database index (the AI's weights are indexed by it) |
| | `+72` | kind: 1 tradition, 2 ascension perk |
| | `+80` | the category (`CTraditionCategory*`, a null object for perks) |
| | `+984` / `+1176` | `on_enabled` of a swap / of the tradition |
| | `+1560` | `ai_weight` (`CMeanTimeToHappen`, default factor 1.0) |
| | `+1632` | the council agenda it unlocks (`unlocks_agenda`; a message only) |
| | `+1672` | the `tradition_swap`s (count `+1684`) |
| `CTraditionSwap` | `+8` / `+148` | `trigger` / its count; `+224` `weight`; `+1416` `inherit_effects` |
| `CTraditionCategory` | `+72` / `+212` | `potential` / its count |
| | `+288` | `ai_weight` (default factor 1.0) |
| | `+344`, `+352` | the adoption (`adoption_bonus`), the finisher (`finish_bonus`) |
| | `+368` | the category's traditions (count `+380`; the adoption and finisher included) |
| `CCountryAI` (`CAICore`) | `+812`, `+816` | the unsynced generator's position and seed (`_Random`) |
| | `+1392`, `+1404` | `_ExpenditureBudget` (32-byte resource tables per economic category), count |
| `CCountryType` | `+0x8c` | `SCountryAISettings` flags (bit 6 `traditions`, bit 16 `ascension_perks`) |

The databases: `CTraditionTypeDatabase` (`common/traditions`, 234 vanilla traditions),
`CAscensionPerkDatabase` (`common/ascension_perks`, 49), `CTraditionCategoryDatabase`
(`common/tradition_categories`, 33). The index is the load order: files by name, definitions in
file order.

## 2. The cost: `CTraditionType::CalcCost(out, country, tooltip)` (`0x4c0f00`) **[V]**

Static: the tradition does not enter it. Every caller passes only the country: the AI
(`HandleTraditions`, `HandlePlanetaryAscension`), the command, `CanActivate`, edicts
(`CCountry::CalcEdictCost`: the unity ambitions, `EDICT_UNITY_AMBITION_COST_MULT` of the next
tradition), the interface.

```
cost = NResourceUtil::ConstructBaseCostFromDefines(TRADITION_COST_RESOURCES, TRADITION_COST_AMOUNTS)
                                             NEconomy: { "unity" }, { 300 }
n = #country._Traditions                     (adoptions and finishers included; not the perks)
x = n * TRADITION_COST_TRADITION             (NGameplay, 8; fixed-point multiply)
if x != 0: x = ipow(x, TRADITION_COST_TRADITION_EXP)   (1.8; NFixedInt64Internal::ipow,
                                             exp2(e * log2 x) with iLog2/iExp2)
cost[r] += x for every resource r of the base cost
groups = the traditions t of the country with t.category.adoption == t
g = groups * TRADITION_COST_MULT_TRADITION_GROUP       (0.0)
if g != 0: cost *= 1 + g
cap    = (EMPIRE_SIZE_BASE + country_admin_cap_add) * mult(country_admin_cap_mult)
                                             (100; modifier ids 315, 316)
excess = max(empire_size - cap, 0) * mult(empire_size_penalty_mult)                 (id 270)
p      = excess * EMPIRE_SIZE_TRADITION_COST_PENALTY * mult(tradition_cost_empire_size_mult)
                                             (0.002; id 272)
cost *= 1 + p
m = tradition_cost_mult                      (id 273)
if m != 0: cost *= max(1 + m, 0)
if galaxy.traditions > 0: cost *= galaxy.traditions   (CGalaxyConfiguration +216)
```

`mult(x)` is `CModifier::ApplyModifierMult` (`0x36e3c0`) -> `CalcModifierMult` (`0x36e5b0`):
`max(1 + value, definition minimum)`; modifiers whose definition has flag bit 5 are clamped to
[0, 1] first. The cost is not rounded beyond the fixed point. The comment in `00_defines.txt`
("`* (1 + cost_planet*num_planets + cost_system*num_systems)`") is out of date: 4.5 uses the empire
size.

For the 2210.01.01 save (no admin capacity or tradition cost modifiers in its countries): n = 2:
447.03 (49), 450.61 (16777217, size 104); n = 3: 605.06; n = 4: 812.00 (size <= 100), 818.50
(16777219, size 104); n = 5: 1065.08, 1195.02 (16777225, size 161).

## 3. The conditions **[V]**

- `CTraditionType::IsPotential` (`0x4c1da0`): the `potential` trigger, the country as scope.
- `CTraditionType::FulfillsPossibleTrigger` (`0x4c35c0`): the `possible` trigger.
- `CTraditionCategory::IsPotential` (`0x4bb250`): its `potential` (true without one).
- `CTraditionType::IsPossible(country, tooltip)` (`0x4c2140`): the tradition and the country valid;
  `IsPotential`; not `HasTradition`; not `HasAscensionPerk`; with a category: its adoption adopted
  unless this is the adoption ("MUST_ADOPT_TRADITION_CATEGORY"); the finisher needs every other
  tradition of the category's list (+368) ("MUST_ACTIVATE_ALL_TRADITIONS"); then
  `FulfillsPossibleTrigger`.
- `CTraditionType::CanActivate(country, check_slots, tooltip)` (`0x4c2610`): `IsPossible`; a
  tradition (kind 1): `CalcCost` and the economy module's affordability (vfunc `+176`, the
  stockpile at least the cost); a perk with `check_slots`: `CalcTotalAscensionPerkPoints - #perks
  > 0` ("MISSING_ASCENSION_PERK_SLOT").
- `CCountry::HasCompletedTraditionCategory` (`0x74cd70`): the category adopted and its finisher in
  `_Traditions`.
- `has_unlocked_all_traditions` (`CHasUnlockedAllTraditionsTrigger::ActualEvaluate`, `0x197e8f0`):
  `TRADITION_CATEGORIES_MAX` (7) categories adopted and every one completed.
- `CCountry::CalcTotalAscensionPerkPoints` (`0x74d1e0`): the country modifier
  `ascension_perks_add` (id 209), truncated, at most `ASCENSION_PERKS_SLOTS` (8).

## 4. Adoption **[V]**

`CCountryActivateTraditionCommand` (`IsValid` `0x6c6a70`: `CanActivate(country, true)`; `Execute`
`0x6c6ae0`): `CalcCost(country)`, `CEconomyCountryModule::RemoveResources(cost)`, then
`CCountry::ActivateTradition(country, &_Traditions, tradition)`. The perk command
(`CCountryActivateAscensionPerkCommand::Execute`, `0x6c6cf0`) calls `ActivateTradition` with the
perk list and pays nothing.

`CCountry::ActivateTradition` (`0x74cdf0`; `0x4bcc00` is the thunk with `&_Traditions`):

1. the tradition's category, when valid and not in `_TraditionCategories`, is appended to it;
2. the tradition is appended to the list given;
3. unless it is a perk (kind 2), `_pLastPickedTradition` = it;
4. `UpdateTriggeredAndNonTriggeredTraditionAndAPModifiers`, and `InvalidateModifier` when it
   reports a change;
5. `ExecuteTradition` (`0x70c950`): `CTraditionType::OnEnabled`; then, for the tradition's (or its
   swap's) `unlocks_agenda`, a notification message when the agenda is potential and allowed
   (no state change);
6. telemetry for the local human.

`CTraditionType::OnEnabled(country)` (`0x4c2870`):

1. `CRandom::GetIntegerForMacro` (line 760): **one draw of the global generator**, the seed of the
   effect's `CEventScope` (the country as root);
2. the swap (`GetTraditionSwap`, below); the effect is the swap's `on_enabled` when there is a swap
   and it does not `inherit_effects`, else the tradition's; it runs when not empty;
3. with a valid category (a tradition): `COnActionDatabase::PerformEvent("on_tradition_picked")`
   with that scope; then, if the category's finisher is not this tradition and `IsPossible`, it is
   activated: `CCountry::ActivateTradition(finisher)` (no cost; its own `OnEnabled`, draw and
   on_action follow);
4. without a category (a perk): `on_ascension_perk_picked`.

`CTraditionType::GetTraditionSwap` (`0x4c0890`): over the swaps in order, those whose trigger holds
(or that have none); the first is taken, a later one only with a strictly greater `weight`
(`GetRawFactor`). Swaps change the name, icon, modifiers and `on_enabled`.

## 5. The AI

### When: `CAIInteriorMinister::MonthlyUpdate` (`0xbb40f0`) **[V]**

On the AI's month (the per-country 30-day counter, ai.md section 1), after the economic plan,
threatened systems, slaves, species rights, factions, jobs, delving, `HandleEdicts`, species
modification and uplift, resettlement, deposit blockers, terraforming, observation stations and
megastructures:

```
if flags & (1 << 6) (traditions) and not WasHumanRecently:
    HandleTraditions
    if flags & (1 << 16) (ascension_perks) and CalcTotalAscensionPerkPoints - #perks > 0:
        HandleAscensionPerks
    HandlePlanetaryAscension
```

`flags` is `SCountryAISettings` of the country type (`CCountryType +0x8c`). `CCountryType`'s
constructor sets it to **36798** before `ai = { }` is read: bits 6 and 16 are off, so only a type
with `traditions = yes` / `ascension_perks = yes` runs these (the `default` type has both; fallen
empires neither, though they hold thousands of unity).

### `CAIInteriorMinister::HandleTraditions` (`0xbc3250`) **[V]**

```
all_completed = AND over country._TraditionCategories of HasCompletedTraditionCategory
if all_completed and #categories >= TRADITION_CATEGORIES_MAX: return           (no draw)
w[0..N) = 0 (CFixedPoint, N = the tradition database's size); adopted = the country's traditions
for i, t in the tradition database:
    if adopted[t] or not t.category valid: continue
    c = t.category; idx = position of c in the country's categories (-1: none)
    if not all_completed and idx == -1: continue
    if idx == -1 and c.adoption != t: continue
    cost = CalcCost(country)                                  (same every time)
    budget category = the economic category "traditions" (CString at 0x2859890)
    if c.adoption == t:
        if c.IsPotential(country) and t.IsPossible(country):
            if not CanAffordExpenditure("traditions", cost): return       (no draw)
            w[t.index] = c.CalcAIWeight(country)              (CTraditionCategory::CalcAIWeight,
                                                               0x4bb450: GetRawFactor of +288)
    if idx != -1:
        if t.FulfillsPossibleTrigger(country):                (only `possible`: the finisher is
                                                               a candidate, with its default 1.0)
            if not CanAffordExpenditure("traditions", cost): return       (no draw)
            w[t.index] = t.CalcAIWeight(country)              (CTraditionType::CalcAIWeight,
                                                               0x4c39c0: GetRawFactor of +1560)
r = the unsynced AI draw, inline: noise(position, seed) of CAICore::_Random, position + 1, & 0x7fffffff
i = GetWeightedRandomInternal<CFixedPoint>(N, w, r, fallback -1)   (0x1b4ad80, ai.md section 4)
if i < 0: return                                            (no positive weight)
t = database[i]
if t.CanActivate(country, true): post CCountryActivateTraditionCommand(country, t)
```

The weights are the raw `CFixedPoint` integers (1000.0 = 100,000,000). `GetRawFactor`
(`CMeanTimeToHappen`, `0x342930`): the factor, then each modifier whose triggers hold, in order.
No global draw is made while deciding.

Picking the finisher (weight 1.0 against 1000s) posts nothing that month (its `CanActivate` fails
while other traditions of the category are missing), after the draw.

### The budget: `CCountryAI::CanAffordExpenditure(category, cost, out)` (`0xb78f00`) **[V]**

`GetEconomicCategoryToUse(category)` (the category itself for `traditions`: `use_for_ai_budget =
yes`, no `ai_use_parent_for_resources_*`); invalid -> false; a zero cost -> true; per resource
`GetBudgetCategoryForResourceExpenditure` picks the table; the test is `budget[r] >= cost[r]` for
each resource (a negative budget with no cost is skipped). The tables are
`_ExpenditureBudget`, rebuilt at the start of the same AI month by `CCountryAI::MonthlyUpdate`
(`0xb6ddc0`: `SetBudgetArraySize`, `UpdateUpkeepBudget`, `UpdateExpenditureBudget`) and not
withdrawn from by `HandleTraditions` (it posts with `AddAICommandForPosting`, not `...WithCost`).

`UpdateExpenditureBudget` (`0xb716b0`), per resource R:

```
for each common/ai_budget entry with type expenditure (2), resource R, a valid category, potential:
    W[c] += weight; total += weight; MAX[c] += desired_max; MIN[c] += desired_min
    (GetBudgetWeight / DesiredMax / DesiredMin: GetRawFactor of the blocks)
S = the stockpile of R (CEconomyCountryModule::GetResource)
pass 1, per category c with W[c] > 0 or MIN[c] > 0:
    S <= 0: f[c] = 0
    share = total != 0 ? W[c] / total : 0xffffffff (raw)
    a = share * S        (a resource whose definition has +272 >= 0, a maximum [I]:
                          a = min(a, CStrategicResource::GetMaximumForCountry * share))
    v = a < MIN[c] ? MIN[c] : min(a, MAX[c] > 0 ? MAX[c] : a);  v = min(v, S)
    f[c] = v / S;  F += f[c]
pass 2, per category: f[c] <= 0: budget 0; else budget[c][R] = max(S * f[c] / F, min(MIN[c], S))
```

For unity (`04_unity_budget.txt`): `traditions` weight 0.8 with `desired_min = 100000` (potential
`has_unlocked_all_traditions = no`), edicts 0.2 above 300 unity, megastructures 0.1 above 7500:
the traditions budget is min(100000, S) = **the whole stockpile**. So the AI adopts on the first AI
month where the stockpile reaches the cost (the command's `CanActivate` checks the same stockpile).

### `CAIInteriorMinister::HandleAscensionPerks` (`0xbc3880`) **[V]**

```
list, w = [], []
for each perk p of the perk database, in order:
    if p.CanActivate(country, true) and (x = p.CalcAIWeight(country)) > 0: append p, x
r = the unsynced AI draw (made even when the list is empty)
i = GetWeightedRandomInternal(#list, w, r, -1); i < 0: return
if list[i].CanActivate(country, true): post CCountryActivateAscensionPerkCommand(country, list[i])
```

`HandlePlanetaryAscension` (`0xbc3ec0`, `CalcCost` and `PLANETARY_ASCENSION_ALLOWED_SPENDING`) is not
read or ported.

### The random streams

- The pick draws the AI's **unsynced** generator (`CAICore::_Random`), restarted at the country id
  when a save is loaded (ai.md section 1). Before `HandleTraditions` in the same AI update, the
  research choice (3 a day), the foreign minister's daily draws and the interior minister's
  monthly handlers (edicts, deposit blockers, buildable specialization, ...) draw it too; until all
  of these are ported, the stream position at the pick differs from the game's, so the choice can
  only be compared in distribution.
- Each `OnEnabled` draws the **global** generator once (the effect scope's seed); the
  `on_enabled` effect and the on_action's events may draw more.

## 6. In the simulation

`sim/lua/engine/traditions.lua` (game logic):

| function | game |
|---|---|
| `types()`, `perk_types()`, `categories()`, `type(name)`, `category(name)` | the three databases in load order, each tradition's category |
| `of`, `categories_of`, `perks_of`, `has`, `has_perk`, `has_category`, `completed_category`, `unlocked_all` | the save's lists; `HasCompletedTraditionCategory`; `has_unlocked_all_traditions` (the simscript trigger, through `E.unlocked_all_traditions`) |
| `cost(country[, tradition])` -> `{ unity = x }, x` | `CalcCost` (doubles; the stockpile's 5 decimals) |
| `is_potential`, `fulfills_possible`, `category_potential`, `is_possible`, `can_activate`, `perk_points` | section 3 |
| `swap(country, name)` | `GetTraditionSwap` |
| `activate(country, name, host[, date])` | the command: `CanActivate` (slots checked), the cost paid, `add` |
| `add(country, name, host)` | `CCountry::ActivateTradition` + `OnEnabled`: lists, `last_picked_tradition`, `economy.invalidate()`, one `E.rand` draw, `on_enabled` through `simscript.eval.effect` (then `eval.sync`), `host.on_action("on_tradition_picked" / "on_ascension_perk_picked")`, the finisher |

`sim/lua/engine/ai/traditions.lua` (the AI), called by `engine.ai` on each AI country's month
(`ai.INTERIOR`): `monthly(country, today, commands, host)` checks the type's flags (`setting`,
with the constructor's default 36798), runs `handle_traditions` and, with a free slot,
`handle_perks`, drawing `engine.ai.rng.draw(country)`; the commands call
`traditions.activate`. The budget test is `engine.ai.budget.can_afford_expenditure` (the budgets
made on the AI's month by `CCountryAI::MonthlyUpdate`, docs/ai_economy.md) when that module is
there; else `expenditure_budget(country, resource)` here, `UpdateExpenditureBudget` for one
resource (both give the same adoptions on the check below). `STELLAR_AI_TRADITIONS=off` turns the module off (to measure a run without it). Records:
`stats`, `months` (each AI month's outcome), `picks` (with the candidates and weights).

## 7. Check: 2210.01.01 + 180 days against the game's 2210.07.01

(`examples/diff`, the capture `modifier-nodes-2210.tsv`; probes in `tmp_trad/`.)

The cost against the saves: every country with traditions, its cost, and its unity at both ends.

| country | n | cost | unity 01.01 | game 07.01 | sim 07.01 | |
|---|---|---|---|---|---|---|
| 16777219 | 4 -> 5 | 818.50 | 761.79 | 27.97 | 32.14 | adopted |
| 49 | 2 -> 3 | 447.03 | 439.07 | 33.82 | 47.53 | adopted |
| 16777218 | 4 | 812.00 | 605.87 | 695.60 | 694.52 | never reaches the cost |
| 16777224 | 3 | 605.06 | 505.39 | 570.03 | 570.01 | |
| 6 | 5 | 1065.08 | 743.94 | 910.01 | 724.60 | |
| 16777225 | 5 | 1195.02 | 565.18 | 733.94 | 735.61 | |
| 16777217, 16777221, 16777223, 50 | 2-5 | 450.6-1065.1 | 103-297 | 156-412 | within 1 | |
| 11, 16777226 (fallen empires) | 0 | 417.6, 405.6 | 30044, 6187 | 0 adopted | 0 adopted | type flag off |

- The formula is consistent with every country: none of the nine that did not adopt has its cost
  in stock at either end (nor in the simulation's months between); the two that adopted end with
  `start + income - cost`.
- **When.** The simulation adopts on 2210.02.19 (49, stock 448.32) and 2210.05.19 (16777219, stock
  821.02), the AI months (day 19 = id % 30 after the load) where the stock first reaches the cost.
  The game's end stocks imply an average net income of 6.96 (49) and 14.11 (16777219) unity a
  month against the simulation's 9.25 and 14.81: at those rates the game's stock reached the cost
  one AI month later (2210.03.19, 2210.06.19). The difference is the economy's (the unity income),
  not the adoption rule.
- **Which.** 16777219 chose among `tr_supremacy_war_games` (1000), `tr_supremacy_great_game` (1000)
  and the finisher (1): the game took great_game (49.98%), the simulation war_games. 49 chose among
  `tr_mercantile_commercial_enterprise` (5000), `tr_mercantile_adaptive_economic_policies` (1000)
  and the finisher (1): the game took adaptive (16.66%), the simulation commercial_enterprise. The
  choice is random given the weights; the AI stream cannot be aligned yet (section 5).
- **Stockpiles** (the diff's `stockpiles:`): unity 47.6% of the change explained -> **81.1%** (off by
  1978.9 -> 713.4 over 13 countries). What is left: the fallen empire 11 (+506), country 6 (-185),
  49 (+13.7, its income), 16777219 (+4.2). Fields equal: 697,867 -> 697,921 (95.1%).
- No perks in the window, as in the game (fallen empires have perk points but not the flag).

## 8. Open questions and what is not ported

- The AI stream before `HandleTraditions` (other unsynced draw sites), and the global draws of the
  other root effects (the script layer draws no scope seeds yet).
- The tradition modifiers (`modifier`, `triggered_modifier`, the swaps'): the capture is fixed at
  2210.01.01; with the world's own modifier graph, `UpdateTriggeredAndNonTriggeredTraditionAndAPModifiers`
  has to add them.
- `empire_size` is the saved value (the game's grew 104 -> 105 for 16777219, which makes the cost
  820.12); `ipow` is computed in doubles, not with `iLog2`/`iExp2`.
- `HandlePlanetaryAscension`, `on_disabled`, tradition removal, `CopyTraditions`,
  `RepairTraditions`, `WasHumanRecently`.
- The definition minimum of `CalcModifierMult` (`+160` of a modifier definition) is taken as 0.
