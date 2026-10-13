# Leader experience (4.5.2)

How leaders gain experience each month and level up. Read from the GOG 4.5.2 build. **[V]** = read
in the disassembly, **[I]** = inferred from the saves. Ported in `sim/lua/engine/leaders.lua`.

## The month's experience **[V]**

`CCountry::MonthlyUpdateSerial` (`0x6f4b10`), for a country with a government:

| who | amount |
|---|---|
| the ruler | `LEADER_RULER_EXPERIENCE` |
| the heir | `LEADER_HEIR_EXPERIENCE` |
| each councilor of the government's council positions | `LEADER_COUNCILOR_MONTHLY_EXPERIENCE` |

The council is the government's own `council_positions` list. The ruler sits on the council too, in
the authority's ruler seat (`councilor_ruler_<authority>`), which isn't in that list.

Then `CStandardLeaderCountryModule::MonthlyUpdateSerial` (`0x7fabb0`) gives every owned leader
`LEADER_ASSIGNED_MONTHLY_EXPERIENCE` when all three hold:
- its class can have traits (`can_have_traits`, `ELeaderClassAbility` bit 14);
- it isn't the ruler;
- it isn't idle.

`CLeader::IsIdle` (`0x8903a0`): a leader is idle when it has no location (a fleet, planet, army,
federation, ...) and isn't on the council. Where the country can't change its councilors
(`CGameRules::CanCountryChangeCouncilors`, `0x5bee70`, the game rule
`can_country_change_councilors`, i.e. gestalts), the ruler and councilors aren't idle either.

## `CLeader::AddExperience` (`0x88fb60`) **[V]**

```
cap = min(LEADER_MAX_SKILL_CAP, LEADER_BASE_SKILL_CAP + leader_skill_levels + <class>_skill_levels)
                                                         (CLeader::CalcSkillCap, 0x8a1770)
nothing at the cap
gain = amount * max(0, 1 + species_leader_exp_gain + <class>_exp_gain
                         + on the council: councilor_exp_gain + <position type>_exp_gain)
            * LEADER_CAPACITY_XP_SCALE ^ (leaders of the class over the class's cap)
experience += gain
while below the cap and experience >= requirement(level + 1):
    experience -= requirement(level + 1); level + 1           (CLeader::LevelUp, 0x8998e0)
requirement(level) = sum over k from LEADER_SKILL_MIN to the level of (BASE + k * SCALE)
```

### The leader cap penalty

`CCountry::CalcLeaderCapExceededXpPenalty` (`0x748cb0`) **[V]**:
- the class's cap is its `leader_capacity` (a script value) + `country_leader_cap_add` + `country_<class>_cap_add`. A class without one has no penalty;
- the leaders counted are the class's owned leaders that satisfy the game rule `should_count_towards_leader_cap`.

That rule reads `is_hidden`. In the save that is bit 9 of `leader_flags` **[I]**: it matches the 835 leaders on gestalt council nodes and the envoys the rule leaves out.

## Check

180 days, 2210.01.01 → the game's 2210.07.01:
- 35 of 401 leaders differ in experience (117 before the cap penalty and the hidden leaders);
- every commander matches;
- the rest are mostly scientists' survey experience.

## Not ported

- The experience of fleet orders (surveys, anomalies, reconnaissance), combat, special projects, archaeology and effects. Effects' `add_experience` goes through `leaders.add_experience`.
- The traits a level-up offers.
- Leader cooldowns and aging.
