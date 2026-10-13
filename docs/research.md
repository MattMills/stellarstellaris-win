# Research (4.5.2)

How the game advances research, costs technologies, completes them and draws the options it
offers. Read from the GOG 4.5.2 build. **[V]** = read in the disassembly, **[I]** = inferred from
the saves. Ported in `sim/lua/engine/research.lua`; the AI's choice among the options is
`sim/lua/engine/ai/research.lua` (docs/ai.md section 4).

## The save's form

```
tech_status = {
    technology = "tech_x" level = 1 ...           # the researched ones, in order
    physics_queue = { { progress = 959.31163 technology = "tech_fusion_power" date = "2205.12.02" } }
    society_queue = { ... } engineering_queue = { ... }
    stored_techpoints = { 0 0 0 }                  # physics, society, engineering
    alternatives = { physics = { "tech_a" ... } society = { ... } engineering = { ... } }
    potential = { "tech_b" = "2" ... }             # _TechPotentialCount
    always_available_tech = "tech_c" ...
    last_increased_tech = "tech_x"
}
```

A queue item is a technology or a special project (`special_project = <id>`, the id of the
country's `events = { special_project = { id special_project = "KEY" ... } }`).

## When

`CTechnologyStatus::DailyResearch` (`0x818de0`) runs every day for every country, from
`CCountry::DailyUpdateSerial` after the country's events **[V]**. The month's research goes to the
queues on the month's second day (day 1 counting from 0) **[V]**. The rest of the days only
complete items already at their cost and top up the options.

## The month's research: `CalcResearchPerMonth` (`0x8188c0`) **[V]**

For each area, with R the area's resource (`physics_research`, ...) in the country's budget
balance of the month:

```
A = max(0, R * (1 + efficiency))
B = min(R, max(0, stored))                  the stored points drawn, at most the month's research
for each queued item in order:
    progress += A + B;  stored -= B;  A = 0  (the first item takes A)
stored += A                                 what no item took (an empty queue keeps it all)
```

The progress is held to 5 decimals, as the save writes it.

### Efficiency: `CalcResearchEfficiency` (`0x817b10`) **[V]**

For the first technology still to research in the queue:

- `all_technology_research_speed`;
- `country_<area>_tech_research_speed`;
- `category_<c>_research_speed_mult` for each of its categories;
- `rare_`, `dangerous_` and `insight_tech_research_speed_mult`, by the technology's flags;
- `TECH_RESEARCH_NO_LEADER_PENALTY` when there is no head of research.
  - `CGovernment::GetHeadScientist` (`0x64b660`) finds the head: the leader of a council position listed in `COUNCIL_RESEARCH_POSITIONS`.
- The tech sharing of research agreements (`GetTechSharingMult`) is not ported. The 2210 saves have none.

## The cost **[V]**

`CTechnology::GetCostForLevel` (`0x428170`):

- **Base:** the base is `cost = @tierNcostM`, or a weight-like block in the country's scope: `factor`/`base`, then each `modifier = { factor add <triggers> }` whose triggers hold.
- **Levels:** for a repeatable technology, `cost_per_level` × (the level to research) is added.
- **Difficulty:** the result is multiplied by `1 + TECH_COST_DIFFICULTY_SCALE_MULT × tier × difficulty × tech scaling` (the galaxy settings) and rounded.

`CTechnology::GetCost` (`0x426fc0`):

```
cost = round(base * (fe + penalty) * (1 + subject_tech_cost_mult, when the overlord has it)
             * (1 + <area>_tech_cost_mult) * galaxy.technology)
fe = TECH_COST_MULT_FALLEN_EMPIRE for a fallen empire's country type, else 1
penalty = EMPIRE_SIZE_TECH_COST_PENALTY * max(0, empire_size - admin cap)
          * max(0, 1 + empire_size_penalty_mult) * (1 + tech_cost_empire_size_mult)
admin cap = (EMPIRE_SIZE_BASE + country_admin_cap_add) * max(0, 1 + country_admin_cap_mult)
```

## Completion **[V]**

`CTechQueueItem::IsDone` (`0x814de0`) is true when progress ≥ cost. Then
`CTechnologyStatus::DoResearchTechnologyCompleted` (`0x819db0`) runs:

1. `IncreaseTechnologyLevel` (`0x816f00`): the technology is appended after the last `technology`/`level` entry with level 1, or its level is raised.
2. The item leaves the queue.
3. `last_increased_tech` is set.
4. `on_tech_increased` fires.
5. `IncreasePotentialTechWeights(area)` (`0x81cd30`) adds +1 to `potential` for each technology of the area the country can research that isn't among the alternatives.
6. `UpdateTechAlternatives(area, reset)` (`0x81d960`) draws the options again.

## The options: `UpdateTechAlternatives` (`0x81d960`) **[V]**

- **How many:** `NUM_TECH_ALTERNATIVES + num_tech_alternatives_add` per area.
- **Reset** (after a completion): the options are emptied. Those that were offered get their weight × `TECH_WEIGHT_PREVIOUS_OPTION`.
- **Without reset** (every day, at the end of DailyResearch, for an area that isn't researching): options the country can no longer research are dropped, and the list is topped up.
- **Candidates:** the area's technologies in database order (files in load order, then their order) that the country can research (`CTechnology::CanResearch`, `0x429540`). That means:
  - not researched (or a repeatable below its `levels`);
  - its prerequisites researched;
  - its `potential` holds.
- **Weight:** `CTechnologyStatus::GetTechWeight` (`0x81bd40`):
  - 0 unless `potential` holds;
  - otherwise `(weight + potential count × TECH_WEIGHT_POTENTIAL_ADD) × weight_modifier`, with the country as scope;
  - then `× (1 + <flag>_tech_draw_chance_mult)` for each of rare, dangerous and insight.
- **The pick:**
  - each option is one draw of the synced global random;
  - the pick is `GetWeightedRandomInternal` over the weights as `CFixedPoint` integers. Totals above 2^31−1 scale the draw: target = `floor(r · floor(total·1000/(2^31−1)) / 1000)`;
  - the chosen one is removed by moving the last candidate into its place.
- **Afterwards:** the country's `always_available_tech` of the area that it can research are appended.

## Special projects in the queues **[V]**

- **Research-cost projects:** a project whose type (`common/special_projects`, by `key`) has a research `cost` and no `days_to_research` takes the month's research like a technology, and holds back every item behind it.
- **Days projects:** progress where a ship or army works on the project (`CSpecialProjectInstance::CanProgress`, `0x8225d0`). Not ported.
- **Completion:** `CCountryEventManager::CompleteSpecialProject` (`0x802c50`). Not ported.

## Check

180 days, 2210.01.01 → the game's 2210.07.01:
- in the 29 areas researching the same technology in both, 95.0% of the game's progress is explained (94.8% with the world-built modifiers);
- the two technologies the game completed, the simulation completes too.

What remains is the economy's research income. The AI picks the same first technology in 157 of 159 queues (docs/ai.md).

## Not ported

- Tech sharing.
- Component upgrades.
- The special projects' days and completion.
- Messages.
