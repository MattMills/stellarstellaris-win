# The pop groups' ethics and faction remnant (4.5.2)

How the game updates a pop group's ethics (`ethos.pops`, `ethics_attraction`, `total_attraction`)
and its faction-change remnant (`fractions`) each day, reverse engineered statically from the GOG
4.5.2 build and its PDB on hippo (`/root/fnm_tmp`: `annotate.py`, `pdbtype.py`, `full452.asm`), and
what [`sim/lua/engine/ethics.lua`](../sim/lua/engine/ethics.lua) models of it. Addresses are GOG
RVAs. **[V]** marks what was read in the disassembly, **[I]** what is inferred (names, the script
files, or the saves only). The annotated dumps are in `H:\code_working\tmp_ethics\re\`, the probes in
`H:\code_working\tmp_ethics\probe*.lua`.

Numbers are the game's fixed point (`CFixedPoint`, int64, 1.0 = 100000): `a * b` is
`trunc(a * b / 100000)`, `a / b` is `trunc(a * 100000 / b)` (toward zero), a division by zero gives
`0xFFFFFFFF`. "The day" is `CGameState::_CurrentDateInDays` (`+0xc4`): `year * 360 + day of the year`
(30-day months), the counter every staggered update uses.

## In short

- **Attraction** (`CPopGroup::FillEthicsAttraction`): per ethic of the database, the pop attraction
  (`pop_attraction` weight, This = the group, From = its planet, times `1 + pop_<ethic>_attraction_mult`
  of the group's node, floored at 0) times the owner's cached country attraction (`country_attraction`
  weight, This = the country, refreshed every 30 days per country, the save's country
  `ethics_attraction`). The values under `POP_ETHOS_MIN_ATTRACTION` (1.1) are set to 0 and left out
  of `total_attraction` (unless none reaches it).
- **The attraction is only written when it is used**: on a successful drift roll (and when a group's
  ethos is created). The save's `ethics_attraction` / `total_attraction` are those of the group's
  last roll, often months old.
- **Drift** (`CPopGroup::EthicChangeSafePrivate`): every `POP_ETHOS_DIVERGENCE_INTERVAL` (18) days per
  group (`(id + day) % 18 == 0`, the interval divided by `1 + pop_ethics_shift_speed_mult`), a roll from
  the day's pool: `pool[(id + 1160) % 1000]` seeds a noise stream; the first `GetInt64 % 1.0` below
  `POP_ETHOS_DIVERGENCE_RATE_MULT` (5%) succeeds. Then the target ethos is the attraction's
  distribution (`round(size * a / total)`), and `n = ceil(size * u)` pops move, `u` a second draw in
  `[0.05, 0.1 + clamp(shift speed, 0, 1)]`: the ethos is shrunk to `size - n`, the target (shrunk to
  `n`) added, and resized back to the size.
- **Faction remnant** (`CPopGroup::CheckPopFactionChange`, `CalculateFactionChange`): on days without
  an ethic change, every 30 days per colony (`(colony + day) % 30 == 0`) or the day after an ethic
  change, `size * POP_CHANGE_FACTION_CHANCE` (0.002) pops move toward the factions they want; the
  fractional part is kept per faction in `fractions` (`-1` = no faction). With no faction in the
  country (the 2210 saves) all the group's pops are in -1 and want none: `fractions.-1` goes down by
  `0.004 * size` each update, less its integer part.
- **Checked**: at load, the countries' attraction 50 of 55 exact, the pop groups' 27 of 126 (most
  saved values are stale, section 10); over 180 days the remnant matches the game in 81 to 82 of the
  87 to 88 groups neither side's ethos changed (the others: the game's rolls, which force an update).
  The day's pool is not the game's (the generator is not aligned, section 8): the drift compares as a
  distribution, 14 groups changed at the same size in the game, 9 to 18 here (three runs), 4.5 to
  4.8% of the rolls succeeding (5% expected).

## 1. Where in the day **[V]**

| phase (simulation.md) | game | what |
|---|---|---|
| 12 par | `CCountry::DailyUpdateOnlyChangeSafePrivate` (`0x6efbf0`, `0x6efde1`) | every 30 days per country (`(id + day) % 30 == 0`): `UpdateCountryEthicsSafePrivate(pool[(id + 4713) % 1000])` into the country's safe struct (`_SafePrivate._EthicsAttraction`, `+0x28 + 0x68`, flag `_DirtyEthicsAttraction`), then `UpdatePopsEthicsSafePrivate` (the country's pops-ethics caches, not modelled) |
| 20 par | `CGameState::DailyUpdate` `lambda_40` (`0x261140`) -> `CPopGroup::DailyUpdateOnlyChangeSafePrivate(group, safe, _CurrentDateInDays, pool)` (`0x676d10`) | groups not ToBeKilled (`_Properties & 1`); the safe struct is `SPopGroupDailySafePrivate` (632 bytes, section 6) |
| 20 par | in it: `CanJoinFactions`, the safe faction maps reset from the group, `EthicChangeSafePrivate(group, safe, day, pool, &unchanged, owner)` (`0x677d00`), then **only when `unchanged` and the owner is valid** `CheckPopFactionChange(group, safe, day, ?, colony, owner)` (`0x675d80`) | `0x6770f3`..`0x677241` |
| 20 par | `CPopGroup::DailyUpdateSelfDoNotReadOthers` (`0x677400`) | the safe `_FactionChangeRemnant` (`+0x1f0`) copied to the group's (`+0x390`) every day; the safe flag 2 copied back to `_Properties` bit 1 |
| 20 ser | `CPopGroup::DailyUpdateSerial` (`0x677800`) | the attraction written (flag 32), the ethos changed (flags 1, 8 or the drift), `OnEthicsDivergence`, `_Properties |= 2`; the factions (section 5) |

## 2. The countries' attraction **[V]**

`CCountry::UpdateCountryEthicsSafePrivate(country, v, out)` (`0x756ba0`): `out` sized to the ethics
database; a noise stream from `v` (`position = noise(v, 0x5EA6BA9F)`), and per ethic `i` in database
order `out[ethic +8] = CEthic::CalcCountryAttraction(ethic, country, noise(position + i) & 0x7FFFFFFF)`
(the last argument only seeds the weight's event scope). Copied to `CCountry::_EthicsAttraction`
(`+0x2790`, the save's country `ethics_attraction`).

`CEthic::CalcCountryAttraction` (`0x45a6a0`): `max(0, weight)` of the ethic's `country_attraction`
(`CEthic +1360` base, `+1376` modifiers), This = the country (scope type 4). An ethic without one (the
fanatic ones, gestalt) has 0.

## 3. A pop group's attraction **[V]**

`CPopGroup::FillEthicsAttraction(group, &list, &total, cached)` (`0x683ed0`):

```
list = {}, total = 0, all = 0
for each ethic of CEthicDatabase (in the order read: common/ethics/00_ethics.txt):
    a = CalcAttractionFor(group, ethic, cached); list += a; all += a
    if a >= POP_ETHOS_MIN_ATTRACTION: total += a
if total <= 0: total = all                       -- nothing at the minimum: all kept
else: every a < POP_ETHOS_MIN_ATTRACTION set to 0
```

`CPopGroup::CalcAttractionFor(group, ethic, cached)` (`0x683ce0`): the owner (the colony's carrier's
owner), `p = CEthic::CalcPopAttraction(ethic, group, owner, colony)`, and the country part: when
`cached`, the owner's `_EthicsAttraction[ethic +8]` (0 when out of range), else
`CalcCountryAttraction(ethic, owner, day + ethic index)`; the result `p * c`.

`CEthic::CalcPopAttraction` (`0x459e90`): without modifiers `max(0, base)`; else the weight of
`pop_attraction` (`CEthic +1304` base, `+1320` modifiers) with This = the pop group (scope type 32),
From = the planet (by the group's colony ref), then `CEthic::ApplyPopAttractionModifier` (`0x45b1d0`):
the group's node value of the ethic's modifier (`CEthic +1600`: `pop_<ethic>_attraction_mult`,
clamped to [0, 1] when the definition's flag bit 5 is set, 0 when absent), `value *= 1 + m`; then
`max(0, value)`.

Who calls it: `EthicChangeSafePrivate` with `cached = yes` (the drift), `CPopGroup::RandomizeEthics`
with `cached = no` (a group whose ethos is empty), `CPopGroup::Initialize`, `OnNewGameStarted`. The
save's `total_attraction` and `ethics_attraction` are the group's `_TotalAttraction` (`+0x3b0`) and
`_EthicsAttraction` (`+0x3b8`), written only when the total is not 0 (`CPopGroup::WriteMembers`
`0x673cea`), and changed only by those callers: **on a successful roll**, not every day.

## 4. The drift

### 4.1 `CPopGroup::EthicChangeSafePrivate` (`0x677d00`) **[V]**

```
if size <= 0: return                                        -- unchanged
random = CalcHasRandomEthics(group)
if not random:
    if ethos empty: return
    flags |= 1 (clear the ethos); unchanged = no; return
if ethos empty: flags |= 8 (CPopGroup::RandomizeEthics); unchanged = no; return
if owner invalid or not owner's country type ShufflePopEthos (ECountryTypeFlags bit 20,
   `shuffle_pop_ethos = yes`: default, primitive): return
m = the group's node value of pop_ethics_shift_speed_mult (id 22; absent: 0, interval as is)
    (clamped to [0, 1] if the definition says so); 1 + m <= 0: return
interval = POP_ETHOS_DIVERGENCE_INTERVAL, or round(interval / (1 + m)) (halves away from zero)
if (id + day) % max(interval, 1) != 0: return               -- unsigned 32 bit
s = CNoiseRandom { position = noise(pool[(id + 1160) % 1000], 0x5EA6BA9F), seed = 0 }
if GetInt64(s) % 1.0 >= POP_ETHOS_DIVERGENCE_RATE_MULT: return
FillEthicsAttraction(group, &safe.list, &safe.total, cached = yes); flags |= 32
CPopGroupEthos::RandomizeEthics(&safe.new, safe.list, safe.total, size)
if safe.new is empty: log "Could not randomize ethics for", n = 0
else:
    lo = max(0, SIZE_CHANGE_MIN); hi = max(SIZE_CHANGE_MAX, lo) + clamp(m, 0, 1) / SHIFT_SPEED_DIVIDER
    (lo, hi ordered); u = lo + GetInt64(s) % (hi - lo + 1)   -- fixed point units
    n = ceil(size * u)
safe.n = n; unchanged = no
```

`id` is the group's full reference (the save's key), the pool the day's 1,000 draws
(`CGameState::DailyUpdate` `0x25e6a0`). `CNoiseRandom::GetInt64` (`0x1b50900`):
`((noise(p) & 0x7FFFFFFF) << 32) + noise(p + 1)`, `p += 2` ([pops.md](pops.md) section 2).

`CPopGroup::CalcHasRandomEthics` (`0x683ba0`): the species is sapient (`CSpecies +0x53c` bit 0), the
group has happiness (`CPopGroup::HasHappiness`: the rule `species_has_happiness`) and the rule
`pop_group_has_random_ethics` (`CGameRules::PopGroupHasRandomEthics`: This = the species, From =
the owner; vanilla: not an organic trophy).

### 4.2 The target: `CPopGroupEthos::RandomizeEthics` (`0x4562e0`) **[V]**

No draws despite the name. Nothing when the list does not have one entry per ethic, the size or the
total is not positive. Else the ethos cleared, and per ethic with `a > 0`: the most attractive kept
(the first on a tie), `k = round(size * (a / total))` (halves away from zero), `SetPops(ethic, k)` when
`k > 0`: an ethic is kept only when `IsElementValid` (`CPopGroupEthos` `0x4565c0`: `use_for_pops`,
`CEthic +297`; the fanatic ethics have `use_for_pops = no`), as its regular variant
(`CPopGroupEthos::AddElement` `0x456580`). Nothing kept: all the pops to the most attractive. Then
`Validate` and `Resize(size)`.

### 4.3 Applying it: `CPopGroup::DailyUpdateSerial` (`0x677800`) **[V]**

```
flags & 32: _TotalAttraction, _EthicsAttraction = the safe's (the save's total/ethics_attraction)
safe.new not empty and n > 0:
    old = the ethos
    ethos.Resize(size - n)
    ethos.AddStat(safe.new, n)        -- a copy of the target resized to n, added ethic by ethic
    ethos.Validate(); ethos.Resize(size)
    d = CalcPopsDiff(ethos, old)      -- min(the pops gained, the pops lost)
    d > 0: OnEthicsDivergence(d)
    _Properties |= 2; InvalidateModifier
flags & 8: d = CPopGroup::RandomizeEthics (0x683fc0: FillEthicsAttraction into the group itself with
    cached = no, CPopGroupEthos::RandomizeEthics on the group's ethos; returns the size, or -1);
    d > 0: OnEthicsDivergence(d); _Properties |= 2
flags & 1: d = the ethos' pops; the ethos cleared; d > 0: OnEthicsDivergence(d); _Properties |= 2
```

`CBasePopGroupStat<CEthic>` (`CPopGroupEthos +0x20`, `_PopAmounts`):

- `Resize(size)` (`0x45d390`): nothing when the stat is empty, its total is 0 or the size; a size of 0
  or less clears it; else each entry `trunc(size * trunc(pops / total))`, the pops left one by one to
  the largest remainders (ties: more pops, then the first), then `Sort` and `ClearNullStats`.
- `Sort` (`0x45df20`): stable, more pops first; on a tie the ethic first in the database
  (`CPopGroupEthos::ShouldComeBefore` `0x4565f0`: `CEthic +8`).
- `Validate` (`0x45d2c0`): entries without pops or invalid set to 0, sorted, removed.
- `AddStat` (`0x689590`): another stat's pops added per ethic (new ones at the end), sorted.
- `CalcPopsDiff` (`0x687720`): over both stats' ethics, `min(Σ gains, Σ losses)`.

`CPopGroup::OnEthicsDivergence(d)` (`0x684640`): **two global draws** (`CRandom::GetIntegerForMacro`,
the event scope's seed), the scope This = the group, From = the owner, the variable
`local_num_pops_changed = d`, and the on_action `on_daily_pop_ethics_divergence` (empty in vanilla).

`_Properties` bit 1 (value 2, set here and by `CForceFactionEvaluationEffect`): the next faction
check runs whatever the day (section 5).

## 5. Factions

### 5.1 `CPopGroup::CheckPopFactionChange` (`0x675d80`) **[V]**

Only on a day `EthicChangeSafePrivate` left `unchanged`, with a valid owner, its
`CPopFactionsCountryModule` (`CCountry +10912`) valid **[I]** (the country type's
`standard_pop_factions_module`: `default` only; the save's country `modules` block), and
`safe._CanJoinAnyFaction` (`CPopGroup::CanJoinFactions` `0x6826a0`: a sapient species and the rule
`pop_group_can_join_factions`, This = the group, Root = the owner).

1. The group's factions it can no longer join, or that hold more pops than the pops with the faction's
   ethics, are listed as left (`CanJoinFaction`, `CountPopsWithEthics`); `AppendOverflowingConcurrentFactions`;
   any left: safe flag 2.
2. When safe flag 2 (forced: `_Properties` bit 1, an ethic change the day before) or
   `(colony id + day) % 30 == 0`: flag 2 cleared, `CPopFactionsCountryModule::FillWantedFactionsFor`
   (`0x68e8f0`; nothing when the country has no faction and no potential faction:
   `_PopFactionsRefs` and `_PotentialFactions` both empty), safe flag 128, `CalculateFactionChange`;
   when it changed something, safe flag 64 and the left factions' remnants.

### 5.2 `CPopGroup::CalculateFactionChange(group, wanted, changed, remnant, owner)` (`0x674cb0`) **[V]**

```
current = the group's CFactionsStat as wanted refs { faction, no type } (pops > 0)
union   = current's factions, then wanted's (in their order)
remnant: the keys not in the union removed (0x6752ca)
per union entry: diff = wanted pops - current pops (fixed); S += |diff|
D = S * 0.5; D <= 0: return no
ratio = min(1, size * clamp(POP_CHANGE_FACTION_CHANCE, 0, 1) / D)
per union entry (key = CWantedPopFactionRef::GetIndex: the faction id; a potential type -2 - its
                 index; none -1):
    mult = 1, or POP_FACTION_ETHIC_ATTRACTION_FACTOR * owner.GetPopsEthicAttraction(the faction type's
           guiding ethic) for a faction type with one and diff > 0
    t = diff * ratio * mult, not beyond diff
    x = t + remnant[key]; k = trunc(x); remnant[key] = x - k
    current pops + k > 0: changed[ref] = current pops + k
return yes
```

The group's `CFactionsStat` always sums to its size: `CPopGroup::ValidateFactions` (`0x6820c0`, daily
and after loading) puts the pops in no faction under the null faction (-1). The save leaves -1 out of
`factions` and `wanted_factions` (`CPopGroup::WriteMembers` removes it from a copy, `0x6739ce`,
`0x673b40`), and writes `fractions` (`_FactionChangeRemnant`, a hash map `int64 -> CFixedPoint`)
when it is not empty.

So in a country without factions (2210): current = `{ -1: size }`, wanted = `{}`, `D = size / 2`,
`ratio = 0.002 * size / D = 0.004`, `t = -0.004 * size`: `fractions.-1` falls by `0.004 * size` each
update and keeps its fractional part (toward zero). E.g. group 520093696 (200 pops, 6 updates in 180
days): -0.9, -0.7, -0.5, -0.3, -0.1, -0.9, -0.7 (the game's -0.7); group 1660944387 on the same
colony had one ethic change, so 7 updates: -0.8.

### 5.3 The serial part (`CPopGroup::DailyUpdateSerial`) **[V]**

Without `_CanJoinAnyFaction`: `ClearFactions` (`0x681f00`). Else: flag 128 -> the group's
`_WantedFactionsStat` and `_FactionsAttraction` from the safe; `ValidateWantedFactions`,
`ValidateFactions`; flag 64 -> `PopulateWithTargetedFactions` (`0x678db0`: the changed pops into the
factions, not read further), `ValidateFactions`.

## 6. Structures **[V]** (`pdbtype.py`)

| type | members |
|---|---|
| `CPopGroup` | `_Properties +0x188` (1 ToBeKilled, 2 force faction evaluation, 4 enslaved, 8 can procreate, 32 can vote), `_ColonyRef +0x1a8`, `_Ethos +0x1b0` (`CPopGroupEthos`: `CEthos` with `_Ethics`, then `CBasePopGroupStat<CEthic>` at `+0x20` with `_PopAmounts`), `_FactionsStat +0x1f0`, `_WantedFactionsStat +0x2b0`, `_FactionsAttraction +0x370`, `_FactionChangeRemnant +0x390` (`fractions`), `_TotalAttraction +0x3b0`, `_EthicsAttraction +0x3b8`, `_Size +0x3d0` |
| `SPopGroupDailySafePrivate` (632) | `_CanJoinAnyFaction +0x30`, `_JoinableFactionTypes +0x38`, `_ChangedFactions +0x50`, `_WantedFactions +0x110`, `_FactionsAttraction +0x1d0`, `_FactionChangeRemnant +0x1f0`, `_TotalAttraction +0x210`, `_EthicsAttraction +0x218`, `_NewEthos +0x230`, `_NumPopsChangeEthic +0x270`, `_PrivateFlags +0x274` (1 clear, 2 force factions, 8 randomize, 16 can vote, 32 attraction, 64 factions changed, 128 wanted factions) |
| `CCountry` | `_SafePrivate +0x28` (`_DirtyEthicsAttraction +0x60`, `_EthicsAttraction +0x68`), `_EthicsAttraction +0x2790` (the save's `ethics_attraction`), `_PopsEthicsAttraction +0x27a8`, the pop factions module `+10912` |
| `CPopFactionsCountryModule` (176) | `_PopFactionsRefs +0x20`, `_PotentialFactions +0x58` |
| `CEthic` | `+8` database index, `+297` use_for_pops, `+1304`/`+1320` pop attraction, `+1360`/`+1376` country attraction, `+1600` the pop attraction modifier |

## 7. Defines **[V]** (`NGameplay`, read by ethics.lua)

`POP_ETHOS_DIVERGENCE_INTERVAL` 18, `POP_ETHOS_DIVERGENCE_RATE_MULT` 0.05,
`POP_ETHOS_DIVERGENCE_SIZE_CHANGE_MIN` 0.05, `_MAX` 0.1, `POP_ETHOS_DIVERGENCE_SIZE_SHIFT_SPEED_DIVIDER`
1, `POP_ETHOS_MIN_ATTRACTION` 1.1, `POP_CHANGE_FACTION_CHANCE` 0.002,
`POP_FACTION_ETHIC_ATTRACTION_FACTOR` 0.3.

## 8. Random draws

- The day's pool: `pool[(group + 1160) % 1000]` (two `GetInt64` of its stream on a roll day: the roll
  and the share), `pool[(country + 4713) % 1000]` (the country attraction's scope seeds only).
- Global draws: 2 per `OnEthicsDivergence` (in the serial pop group phase).
- **The pool is not the game's in the simulation**: the platform seeds its generator with 0 at
  position 0 (`Runtime::new(date, 0)`, examples/run and diff), not the save's `random_seed` /
  `random_count`, and the game itself reseeds between the two saves (2210.01.01: seed -386941723,
  count 14,059,548; 2210.07.01: seed 64429129, count 4,755,436). So which group rolls when differs;
  the drift compares as a distribution (section 10).

## 9. In the simulation: `sim/lua/engine/ethics.lua`

- `ethics.countries_daily(host, date)`, from the daily `countries_parallel` phase: every 30 days per
  country the country attraction, written to its `ethics_attraction` (where the save has one).
- `ethics.pop_groups_daily(host, date)`, from the daily `pop_groups` phase (after `pops.daily` and
  `colonies.pop_groups_daily`): per living group of a colony, `EthicChangeSafePrivate` with
  `RUST.daily_pool()`, `CheckPopFactionChange` (2210 subset below) on unchanged days, then
  `DailyUpdateSerial`'s ethics part. Writes `ethos`, `total_attraction`, `ethics_attraction` and
  `fractions` in the save's form and order. The forced faction flag (`_Properties` bit 1) is kept in
  `ethics.force_faction` (not in the save).
- `ethics.attraction(gid, cached)`, `ethics.country_attraction(cid)`, `ethics.target_ethos`,
  `ethics.resize`, `ethics.check()` (the load-time check), `ethics.report()`.
- Weights in fixed point (`ethics.weight`): `base`, then each `modifier` whose triggers hold
  (`factor`/`mult` multiply, `add` adds), the triggers through the script layer.
- `STELLAR_ETHICS=off` turns both phases off (the before/after switch of the checks).
- `engine/ethics/script.lua` answers, only while ethics evaluates, what the attraction scripts and the
  rules ask that the script layer does not yet: `pop_group_has_happiness`, `has_citizenship_rights`
  (`is_full_citizenship`), `is_same_species` with a country (its founder species) or a leader,
  `check_variable_arithmetic`, `has_election_type`, `is_sector_capital`, `has_opinion_modifier`,
  `is_councilor_type`, `has_faction`, `is_original_owner` (`= <country>` too), the list
  `enslaved_species`; and ethics.lua counts `value:count_councilors_with_ethic` itself (its
  `complex_trigger_modifier` is not a value operation of the script layer).
- **Factions, the subset modelled**: the update of `fractions` where the owner has no pop faction and
  the group wants none (every group of the 2210 saves). With factions or potential factions
  (`FillWantedFactionsFor`, `PopulateWithTargetedFactions`, the factions' guiding-ethic factor, the
  remnant map's hash order) the group is counted (`not modelled`) and left as it is.

## 10. Checks

At load (2210.01.01, `tmp_ethics/probe2.lua`):

| | exact |
|---|---|
| countries' `ethics_attraction` (every 30 days, so at most a month old) | 50 of 55 (21 before the triggers of `ethics/script.lua`) |
| pop groups' `ethics_attraction` + `total_attraction` from the countries' cache | 27 of 126 groups; 1,963 of 2,142 entries |

The pop groups' saved values are those of their last roll (on average a year old): a group whose
inputs changed since (a new tech's `pop_ethic_x_attraction_mult`, a councilor, an occupation) cannot
match. The 5 groups whose attraction the game rewrote between the saves are not matched either
(e.g. group 149's militarist pop part: 3.71 in the game, 1.1 here; country 16777217's militarist 6.3
against 4.2: `FROM_RIVAL_WARS` / `FROM_HOSTILE_NEIGHBORS` and the occupied-planet factor need
`any_war`, `any_rival_country`, `is_neighbor_of`, `recently_lost_war`, `years_of_peace`).

Over 180 days (`tmp_ethics/probe5.lua`, 2210.01.01 -> 2210.07.01; two runs on the tree of the time,
the pool changing with the other systems' draws):

| | run A | run B |
|---|---|---|
| rolls / divergences | 1,020 rolls, 46 succeeded (4.5%), 2,901 pops moved, 243 changed ethic | 1,020, 47 (4.6%), 2,625 moved, 175 changed |
| groups whose ethos changed at the same size (the game: 14) | 18, 7 of them the game's too | 9, 1 |
| pops that changed ethic, same size at all three (the game: 99) | 122 | 26 |
| `fractions` where neither side changed the group's ethos | 82 of 88 | 81 of 87 |
| `fractions`, all groups the game kept the ethos of | 84 of 97 | 84 of 94 |

The remnant's misses where neither side's ethos changed are groups the game rolled for without a
visible change (the target equal to the ethos): the roll still forces the next day's update.

`examples/diff` (2210.01.01 -> 2210.07.01, the tree at d2e8ca7 with the other agents' work of the
moment, `STELLAR_ETHICS=off` against on, run back to back):

| | off | on |
|---|---|---|
| all stores | 717,338 equal / 16,793 differ | 717,233 / 16,898 |
| `pop_groups` | 4,900 / 470 | 4,813 / 557 |
| `ethos.pops.[]` differ | 107 | 136 |
| `fractions.-1` differ | 66 | 47 |
| `ethics_attraction.[]`, `total_attraction` differ | 0, 0 | 60, 28 |
| `country` | 219,869 / 8,551 | 219,851 / 8,569 |

The remnant improves; the ethos and attraction do worse field by field: with a pool that is not the
game's, other groups roll than the game's (each roll moves 5 to 10% of a group), and a roll writes the
attraction computed now (inexact where the scripts are, and different from a stale saved value even
where exact).

## 11. For the platform and the script layer

- **A serial pop group phase**: `OnEthicsDivergence`'s two global draws (and the on_action) belong to
  `CPopGroup::DailyUpdateSerial`, after the parallel pop group phase, which forbids draws. The
  scheduler's `pop_groups` is parallel only; ethics.lua counts the draws it does not make
  (`global draws not made`). A `pop_groups_serial` phase after `pop_groups` in `scheduler.rs` would
  take them (not changed here).
- **The generator**: seeding it from the save's `random_seed` / `random_count` (and the tick's draws
  before the day) would make the day's pool the game's for as long as every draw is modelled.
- **Script layer gaps** met by the attraction scripts (with their counts over 180 days):
  `any_war` and `any_rival_country` iterators, `recently_lost_war`, `years_of_peace`, `is_neighbor_of`,
  `has_federation_type`, `is_hostile_to`, `is_rival`, `is_domineering_to`, the link `sector` on a
  planet (`exists = sector`), `trigger:num_non_aggression_pacts` in script values, and the value
  operation `complex_trigger_modifier` (`count_councilors_with_ethic`, done in ethics.lua for now); the
  triggers of `engine/ethics/script.lua` (section 9) are candidates too.

## Not modelled

- the country's pops-ethics caches (`UpdatePopsEthicsSafePrivate`, `UpdatePopsEthicsChange`: the save's
  `pops_with_ethic`, `ethics_distribution`, `pops_ethics_attraction`, `pops_ethics_change`,
  `pops_ethics_on_colonies`);
- factions: `FillWantedFactionsFor` (`FillFactionRawAttractions`, potential factions), the factions a
  group leaves (`CanJoinFaction`, `CountPopsWithEthics`, `AppendOverflowingConcurrentFactions`),
  `PopulateWithTargetedFactions`, `wanted_factions`, `factions_attraction`, the pop factions themselves
  (`CPopFaction`: support, approval; none in the 2210 saves), the remnant map's hash order;
- the definition flag that clamps `pop_ethics_shift_speed_mult` / `pop_<ethic>_attraction_mult` to
  [0, 1] (not in the files);
- `OnEthicsDivergence`'s draws and on_action (above).
