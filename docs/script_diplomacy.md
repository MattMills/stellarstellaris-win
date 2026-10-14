# Script layer: war, peace and diplomacy

What the script layer answers about wars, relations, attitudes, pacts, rivals, access and
borders, federations, the galactic community, subjects and overlords, and how the fleets'
pathfinder uses the same rules for closed borders.

Everything was read in the GOG 4.5.2 build with its PDB; the addresses are GOG RVAs.

- **[V]**: read in the disassembly.
- **[I]**: inferred, from the save, the script files, the names, or by analogy.

## The files

| file | what it holds |
|---|---|
| `sim/lua/engine/diplomacy.lua` | The world-reading functions: relations and their flags, pacts, counters, rivals, wars, truces, attitudes, subjects, federations, the galactic community, and access. It only reads; nothing draws. |
| `sim/lua/simscript/handlers/diplomacy.lua` | The triggers, values, scope links and iterators. They are added to `eval.TRIG` and `eval.LISTS`, and their values to `eval.TRIGGER_VALUES`. |

`engine.diplomacy` is the one implementation, and these use it:

- **The script layer.** The global TRIG and LISTS tables.
- **The AI's opinion** (`engine/ai/opinion.lua`). Its relation index, `relation`, `rflag`, `rivals` and `at_war` are now `engine.diplomacy`'s.
- **The AI's attitudes** (`engine/ai/attitudes.lua`). `allied` is `engine.diplomacy.allied`.
- **The economy's tables** (`engine/economy/script.lua`). Its local `RELATION_FLAGS` triggers, `has_federation`, `has_federation_perk`, `has_federation_law` and its `federation` link are gone, so the global ones answer there too.
  - Its `has_non_aggression_pact` had read a field the save does not have (`non_aggression_pact`; the save writes `non_aggression_pledge`).
  - Its `has_federation_perk` had read the perks as strings (they are blocks).
- **The fleets.** `engine.diplomacy.install_access_hooks()` fills `engine.fleets.path`'s `hooks.has_access` and `hooks.restricted`, and `engine.fleets.movement`'s `hooks.has_access`. `STELLAR_ACCESS=off` leaves them open, as before.

`trigger:<name>` in a value (`add = trigger:num_non_aggression_pacts`) is the trigger's value, the
game's `GetTriggerValue`. `eval.lua` and `compile.lua` look the name up in `eval.TRIGGER_VALUES`.
This module fills it for its numeric triggers.

## Where the save keeps it

**Relations.** `relations_manager = { relation = { owner country <flag> = yes ... truce wars flags threat trust ... } }`, written by `CRelation::WriteMembers` 0x669d30 **[V]**.

The flags are `ERelationFlags` at `CRelation +0x120`. Each set bit is written as `<name> = yes`:

| bit | save | bit | save |
|---|---|---|---|
| 0 | `hostile` | 14 | `is_rival` (the owner rivals the other) |
| 1 | `neutral` (forced neutrality) | 15 | `closed_borders` (the owner closed its borders to the other) |
| 2 | `friendly` (forced friendly) | 16 | `contact` |
| 3 | `communications` | 17 | at war: the relation's `wars = { }` list |
| 4 | `borders` (bordering) | 18 | `embassy` |
| 5 | `defensive_pact` | 19, 20 | `capitals_connected_through_relay_network(_before)` |
| 6 | `alliance` | 21 | `secret_fealty` |
| 7 | `subject` | 22 | `acquainted_with` |
| 8 | `guarantee` | 23-25 | the enlightenments |
| 9 | `support_independence` | 26 | `has_pre_ftl_trade` |
| 10 | `non_aggression_pledge` | 27 | `waystation_pact` |
| 11 | `commercial_pact` | | |
| 12 | `research_agreement` | | |
| 13 | `migration_access` | | |

The other relation fields used here:

- `truce = <id>`, a reference into the `truce` store;
- `flags = { name = date }`, the relation flags;
- `forced_open_borders = <date>`, `CRelation +0x148`;
- `threat`, `trust`.

The bits come from the enum in the PDB, and the names from the writer's tokens **[V]**.

**Wars.** `war = { id = { attackers = { { call_type country caller } } defenders = { } attacker_war_goal ... attacker_war_exhaustion defender_war_exhaustion ... } }` (`CWar::WriteMembers` 0x8ce8e0, `SWarParticipant::WriteMembers` 0x8f8220) **[V]**.

The country itself keeps two dates, `last_date_war_lost` (`CCountry +0x1424`) and `last_date_at_war` (`+0x1428`).

**The diplomacy module.** `modules = { standard_diplomacy_module = { rivals = { } threats = { } casus_belli contact_rule borders rival defensive_pact ... } }` (`CDiplomacyCountryModule::WriteMembers`) **[V]**.

The counters (`rival`, `defensive_pact`, `migration_pacts`, ...) are a cache written only when they are not zero.

**Federations.** The `federation` store: `{ members = { } leader federation_progression = { federation_type levels experience cohesion laws perks ... <setting> = yes/no } }`.

The settings are 9 bytes at `CFederationProgression +0x2bc`, in this order: `only_leader_builds_fleets`, `allow_subjects_to_join`, `equal_voting_power`, `free_migration`, `research_agreement`, `failed_vote_half_price`, `research_sharing`, `commercial_pact`, `waystation_pact` **[V]**.

**The galactic community.** `galactic_community = { leader members council permanent_council proposed passed failed ... community_formed council_established empire ... }` (`CGalacticCommunity::WriteMembers` 0x622c50) **[V]**.

None of our saves has a formed community. Its fields are read as the writer names them, untested.

**The AI's attitudes.** `ai = { attitude = { { country attitude weight priority date } } }`.

**Country properties.** `faction = { properties = n }`, the `SCountryInstanceProperties` bits:

| bit | property |
|---|---|
| 0 | Hostile |
| 1 | HostileWhenAttacked |
| 2 | AlwaysNeutral |
| 3 | CopyParentHostility |
| 4 | AutoDelete |
| 5 | NeedsBorderAccess |
| 6 | GenerateBorders |
| 7 | NeedsColony |
| 8 | IsPrimitive |

The save writes the block only when the properties differ from the defaults: the empires have none. Without a block, the country type's `faction = { }` keys apply, with their documented defaults (`needs_border_access = yes`, ...) **[V]** enum, **[I]** default rule.

## Wars and peace

| keyword | class | semantics | marks |
|---|---|---|---|
| `is_at_war = yes/no` | `CIsAtWar` 0x1958260 | the country's wars (`CCountry +0x2bb4`) not empty == yes | **[V]** |
| `is_at_war_with = <c>` | `CIsAtWarWithTrigger` 0x194e280 | both valid; the relation's wars (`CRelation +0xf4`) not empty | **[V]** |
| `any_war` / `count_war` / `every_war` | `CWarListBuilder` (inlined) | the country's wars: `CCountryRelationsManager::RecalcWarsCache` 0xab76c0, the union of its relations' `wars`, in relation order, each once | **[V]** |
| `any_war_participant` | `CWarParticipantListBuilder::BuildIDArray` 0x18177d0 | the war's attackers, then its defenders | **[V]** |
| `any_attacker`, `any_defender` | `CWarAttacker/DefenderListBuilder` | the war's side | **[V]** |
| `is_war_participant = { who side }` | `CIsWarParticipantTrigger` 0x1998ef0 | in a war scope: `who` is on `side` (attackers / defenders); no side: in the war; a country: on that country's side. In a country scope: that country, with the war from `war = <target>` | **[V]** |
| `recently_lost_war = yes/no` | `CRecentlyLostWarTrigger` 0x1958460 | months(today) - months(`last_date_war_lost`) <= `TRUCE_YEARS` * 12, where months = year * 12 + day of year / 30 | **[V]** |
| `years_of_peace <op> n`, `years_of_peace = { value <op> n delay = d }` | `CYearsOfPeaceTrigger::GetTriggerValue` 0x19592b0, `ReadMember` 0x1959220 (tokens `value`, `delay`) | max(0, year(today) - delay - year(`last_date_at_war`)) | **[V]** |
| `attacker_war_exhaustion`, `defender_war_exhaustion <op> x` | 0x1958700 / 0x19588c0 | the war's `attacker_war_exhaustion` / `defender_war_exhaustion` (`CWar +0x118` / `+0x120`) | **[V]** offsets, **[I]** names |
| `has_truce = <c>` | `CHasTruceTrigger` 0x1988a60 -> `CCountry::HasTruceWith` 0x701c20 | both valid; a valid truce on the relation, either way | **[V]** call, **[I]** either way |
| `num_truces` | the module's `GetNumTruces` | relations with a valid truce (`UpdateDiplomaticCache`) | **[V]** |

No save of ours has a war or a truce: the 2210.01.01 save and both 10-year standards have none. The
war triggers are false and the iterators are empty in every run. Ending wars, peace deals, truces
and the war-exhaustion dynamics are engine state the simulation does not model (see "Left").

## Relations and pacts

| keyword | class | semantics | marks |
|---|---|---|---|
| `has_embassy = <c>` | `CHasEmbassyTrigger` 0x19a2ef0 | bit 18 of this towards c | **[V]** |
| `has_defensive_pact = <c>` | `CCountry::HasDefensivePactWith` 0x7032e0 | bit 5 | **[V]** |
| `has_non_aggression_pact = <c>` | `CHasNonAggressionPactTrigger` 0x19a17e0 | bit 10 (`non_aggression_pledge`) | **[V]** |
| `is_guaranteeing = <c>` | `CCountry::IsGuaranteedBy(c, this)` 0x703280 | bit 8 of this towards c | **[V]** |
| `is_forced_friendly`, `is_forced_neutral = <c>` | `CHasForcedRelationTrigger<..>` 0x19e59b0 / 0x19e61d0 | bit 2 / bit 1 | **[V]** |
| `has_established_contact = <c>` | `CHasEstablishedContactTrigger` 0x19793b0 | itself, or bit 16 (`contact`) | **[V]** |
| `has_commercial_pact = <c>` | `CRelation::HasCommercialPact(true)` 0x66b270 | bit 11, or both in one federation whose `commercial_pact` setting is on | **[V]** |
| `has_research_agreement = <c>` | `HasResearchAgreement(true)` 0x66ba80 | bit 12, or the federation's `research_agreement` | **[V]** |
| `has_migration_access`, `has_diplo_migration_treaty = <c>` | `CCountry::HasMigrationAccess` 0x739d90 -> `HasMigrationPact(true)` 0x66bbc0 | bit 13, or the federation's `free_migration` | **[V]** |
| `has_waystation_pact = <c>` | (eval.lua, `E.has_waystation_pact`) | bit 27, or the federation's `waystation_pact` | **[V]** |
| `has_rival = <c>` | `CHasRival` 0x19b07f0 -> `CCountry::IsRivaling` 0x72c240 | c among the module's `rivals` | **[V]** |
| `has_association_status = <c>` | `CCountry::HasAssociateStatusWith` 0x716860 | one's `associated_federation` is the other's federation | **[V]** call |
| `has_closed_borders = <c>` | `CHasClosedBordersTrigger` 0x19a3e20 | bit 15 and `CCountry::CanControlAccessFor(this, c)` 0x71c460: not each other's overlord or subject, not one federation, c needs border access, no `forced_open_borders` still running | **[V]** bit and call, **[I]** CanControlAccessFor in part (its agreement and primitive rules are not ported) |
| `is_hostile = <c>` | `CCountry::IsHostile` 0x702100 | the relation's `hostile`, or at war; not with a forced neutrality or friendliness | **[I]**: the parent-country, AlwaysNeutral and diplomatic-wars rules of IsHostile are not ported |
| `has_relation_flag = { who flag }`, `reverse_has_relation_flag` | `CHasRelationFlagTrigger` 0x197d3f0 | the flag in the relation's `flags` (of this towards who, or who towards this) | **[V]** |
| `num_defensive_pacts`, `num_guarantees`, `num_non_aggression_pacts`, `num_commercial_pacts`, `num_waystation_pacts`, `num_research_agreements`, `num_migration_pacts`, `num_rivals`, `num_closed_borders`, `num_truces` | `CNumDiplomacyRelationsTrigger<CDiplomacyCountryModule::GetNum*>` 0x19c8b30..0x19c8ef0 | the module's counters, as `CDiplomacyCountryModule::UpdateDiplomaticCache` (0x6a2c90) counts them; also values (`trigger:num_non_aggression_pacts`) | **[V]** |
| `any_rival_country` | `CRivalCountryListBuilder` | the module's `rivals`, in order | **[V]** list, **[I]** order |
| `trust = { who value }` | `CTrustTrigger` 0x1960850 | the relation's trust (`CRelation +0x118`), truncated to an integer | **[V]** |
| `highest_threat <op> x` | `CHighestThreat` 0x19b1f50 -> `GetLargestThreat` 0x6a3940 | the largest `threat` of the relations towards the module's `threats`, at least 0 | **[V]** |
| `their_opinion = { who value }` | `CTheirOpinionTrigger` 0x1961900 | who's opinion of this (`engine.ai.opinion`) | **[V]** shape, **[I]** that the game's thread cache holds the same value |

The counters follow `UpdateDiplomaticCache` **[V]**. It runs over the country's relations whose other country exists, when both are alive and both country types have `relations = yes` (none when ours has not):

- one counter per flag (defensive pact, guarantee, support, NAP, rivalry, closed borders, secret fealty);
- the four pacts through `CRelation::Has*(true)`;
- the truces when valid.

The game recomputes them at the load (`CGameState::RecalculateCachedData`) and on every diplomatic action. The 2210.01.01 save's cached counters agree with the computed ones in 658 of 660, the exception being the two fallen empires' `closed_borders`: the save says 0 and the relations say 1, a cache from before a closed borders that was set without an update. They are computed, as after the game's load **[I]**.

## Attitudes

`is_hostile_to`, `is_friendly_to`, `is_protective_to`, `is_domineering_to`, `is_cordial_to`,
`is_threatened_to`, `is_overlord_to`, `is_loyal_to`, `is_disloyal_to`, `is_angry_to`,
`is_berserker_to`, `is_enigmatic_to`, `is_patronizing_to`, `is_custodial_to`, `is_dismissive_to`,
`is_imperious_to`, `is_arrogant_to`, `is_belligerent_to` (`CIsAttitudeTrigger<SIs*Impl>`,
0x19e77b0..0x19eb5a0) **[V]**:

- the target is valid;
- the scope country has an AI (`CCountry +0x1b28`, the save's `ai = { }`);
- `CCountryAI::GetAttitude(target)` (0xb7b2b0) is the database's attitude of that name. GetAttitude reads the AI's entry for the target, or the `null` attitude without one.
- `CAIAttitudesDatabase::Init` (0xb3b1e0) caches the attitudes by name.

Three attitude triggers differ:

| keyword | holds for |
|---|---|
| `is_unfriendly_to` | unfriendly or rival |
| `is_neutral_to` | wary, receptive or neutral, or an attitude that is not valid. The `null` attitude is a real one in `common/attitudes`, so no entry means "not neutral" |
| `is_rival` | an AI, and `CCountry::IsRivaling`. Not the rival attitude |

The attitudes are `engine.ai.attitudes`' (updated daily, as the game does).

## Subjects and overlords

| keyword | class | semantics | marks |
|---|---|---|---|
| `has_overlord = <c>` | `CHasOverlord` 0x19b1ae0 | this's `overlord` is c | **[V]** |
| `has_subject = <c>` | `CHasSubject` 0x19b1160 | c's `overlord` is this | **[V]** |
| `has_any_overlord = yes/no` | `CHasAnyOverlord` 0x19b1df0 | a valid overlord == yes; false for an invalid country | **[V]** |
| `subjects <op> n` | `CSubjectsTrigger` 0x198f520 | the count of `subjects` (`CCountry +0x2684`) | **[V]** |

No country of our saves has an overlord or subjects.

## Federations

The federation of a country scope is its `federation` (`CScopeObjectReference::GetFederation`) **[I]** for a country scope.

| keyword | class | semantics | marks |
|---|---|---|---|
| `has_federation = yes/no` | `CHasFederationTrigger` | a valid federation | **[I]** |
| `has_federation_type = <t>` | 0x1a17fa0 | the progression's `federation_type` | **[V]** |
| `federation_level`, `federation_experience`, `federation_cohesion` | 0x1a183e0, 0x1a178d0, 0x1a17d60 | the progression's `levels`, `experience`, `cohesion` | **[V]** |
| `num_members`, `num_associates` | 0x1a18600, 0x1a18810 | the members array's count; the associates' (the countries whose `associated_federation` is it, **[I]**) | **[V]** members |
| `has_federation_perk = <p>` | 0x1a181b0 | a perk entry (`perks = { { level type } }`) of the type | **[V]** |
| `has_federation_law = <l>`, `has_any_federation_law_in_category = <c>` | `CFederation::HasLaw`, `CFederationProgression::GetEnactedLaw` | the progression's `laws = { category = law }` | **[V]** calls, **[I]** reading |
| `has_federation_setting = <s>` | `CHasFederationSetting` 0x1a18c40 | the settings byte | **[V]** |
| `any_federation_ally` | `CFederationAllyListBuilder` | the other members of the country's federation | **[I]** order |
| `any_associate`, `any_federation` | the builders | the associates; every federation | **[I]** |

## The galactic community

| keyword | class | semantics | marks |
|---|---|---|---|
| `is_galactic_community_member = yes/no` | 0x1a044b0 | `members` holds the country (the null country for another scope) | **[V]** |
| `is_part_of_galactic_council = yes/no` | 0x1a04820 | the `leader`, or in `council` | **[V]** |
| `is_galactic_emperor`, `is_galactic_custodian = yes/no` | 0x1a07250 / 0x1a07170 | the leader when the Galactic Empire is (not) formed (`+0x35c & 4`), compared with the scope's country id (-1 for another scope, so with no holder `= yes` holds there) | **[V]** |
| `has_galactic_emperor`, `has_galactic_custodian` | 0x1a07440 / 0x1a07330 | such a leader | **[V]** |
| `is_galactic_council_established` | 0x1a063e0 | `council_established` set | **[V]** |
| `is_years_since_community_formation` | 0x1a05eb0 | -1 when not formed, else the years | **[V]** |
| `is_active_resolution = <r>` | `CGalacticCommunity::IsResolutionActive` 0x62bc10 | the newest passed resolution of the type, unless a newer one of the same category replaced it | **[V]** walk, **[I]** `CResolutionType::CanBeActive` and the category's stacking flag not read |
| `any_galcom_member`, `any_council_member` | the builders | the members; the leader and the council | **[I]** order |

## Borders

| keyword | class | semantics | marks |
|---|---|---|---|
| `is_within_borders_of = <c>`, `is_inside_border = <c>` | 0x194c540, 0x195c5e0 | the owner of the scope's system (a planet's, a ship's fleet's, a fleet's, a system) is c | **[V]** |
| `is_neighbor_of = <c>` | `CIsNeighborOfTrigger<SNeighborOfImpl>` 0x19e7090 | a country: its relation towards c has `borders` (bit 4); another scope: its system is c's or a hyperlane from one of c's | **[V]** country, **[I]** `CalcIsBorderingSystem` |
| `has_potential_claims = yes/no` | `CHasPotentialClaimsTrigger` 0x19ac650 -> `CCountry::HasPotentialClaimTarget` 0x72e9c0 | over the country's relations: `CanMakePotentialClaimOnCountry` 0x72ea70 (see below) | **[V]** |

**Claims.** `CanMakePotentialClaimOnCountry(us, other)` holds when either:

- the other's capital system is claimable; or
- we already have a claim on one of its systems: the system's `claims = { { owner claims } }` with claims > 0 **[I]** `CClaim::IsValid`.

The capital system is claimable (`CGalacticObject::IsClaimableBy(system, us, true, true)` 0x864b50) when all of these hold **[V]**:

- it is not ours (its primary starbase's owner);
- we have intel on it: the country's `intel_level` list by system index **[I]** `GetIntelLevel`;
- it has an owner, and we have communications with it;
- the game rule `can_add_claim` holds, with this = the system and root = the claimer.

The war-ally test is skipped for potential claims.

## Access and closed borders

**`CCountry::HasAccess(us, level, other)`** (0x71bdc0) **[V]** decides whether `us` may enter the borders of `other`. It runs these tests in order:

1. Other invalid, or us: access.
2. A truce and the game rule `is_expelled_from` (this = us, from = other: the country flag `expelled_from_@<other>`): no access.
3. We do not need border access (`NeedsBorderAccess`): access.
4. Level 5: access.
5. Other's type does not enforce borders (`enforces_borders = no`): access.
6. Other is in our federation: access.
7. We are at war with other: access.
8. Other is one of our `war_allies`: access.
9. The galactic community opens its members' territory to us (we lead it, or we have the flag `can_access_community_territory`), and other is a member: access.
10. We are a subject with an active agreement: the overlord's access decides.
11. Other is a subject with an active agreement: its overlord takes its place, and the tests run again.
12. Denied when all of these hold:
    - we have communications with it;
    - its relation towards us has closed borders or a rivalry;
    - our `forced_open_borders` with it has passed;
    - not both relations have a truce.
13. Otherwise: no access for level 4 (a military station), access for every other level.

The subject agreements are read as "an agreement between the two that is not `terminated`" **[I]**.

**The level** (`SFleetPathfindAccessData` 0xe6af60, `CFleet::HasAccess` 0xc821b0) **[V]**:

| level | when |
|---|---|
| 5 | cloaked, or every ship's size has `ignores_closed_borders` (`CFleet::IgnoresClosedBorders` 0xc6bb90) |
| 4 | a military station |
| 3 | any other fleet |
| 6 | no fleet |

The cloaked bit is read as `properties = { cloaked = yes }` **[I]**.

**The pathfinder** (`SFindFleetPathValidatorFuncBase::EvalShared` 0xe73660) **[V]** closes a system when all of these hold:

- its owner is not the fleet's country;
- its owner is not friendly to it (`CCountry::IsFriendlyCached` 0x74e5d0: itself, or not hostile and allied, `CCountry::IsAllied`);
- `CCountry::HasAccessLevelCached(country, system, level)` (0x74e3d0) is false.

That cache (`UpdateSystemStatusCache` 0x74dd10) holds `HasAccess` against the system's owner for each level (bits 8 + level), and a bit 4 for a cosmic storm whose type opens the borders. The simulation computes the cache's answer when asked, and has no storms **[I]** timing.

The restricted systems (`CCountry::IsSystemRestrictedCached` 0x74e190, `restricted_systems`, not the owner's) close a system too **[V]**.

**The movement** asks `CFleet::HasAccess` (the uncached `CCountry::HasAccess(us, level, system)` 0x71bcf0) for each system of its path. That check has no friendliness test **[V]**.

### Fleet paths against the game

The check is over every fleet path the game wrote, using the probe `tmp_sim/dipl/probe3.lua`:

- every save of both 10-year standards, 240 monthly autosaves, 2210.02 to 2220.01;
- 6,101 fleets that are in a system with a path;
- for each, the route from the fleet's system to its path's last system, with and without the access rules, compared with the game's own systems.

| | paths |
|---|---:|
| the game's route = the access rules' route | 5,964 |
| the game's route = the route without access | 5,890 |
| access changes the route | 74 |
| ... and the game's route is the one with access | **74 of 74** |
| the game's route passes a system the rules close | **0** |

The 74 are 11 detours, each seen in several saves. For example:

- Fleet 16777739 (country 16777218) goes 291 -> 307 by 14 jumps in the game (`273,271,8,339,...,188,307`): with the rules, the same; without them, 3 jumps through 443 and 479.
- Fleet 30 (16777223) goes 113 -> 233 by `556,359,226,37,233`, not through 242 and 395, the system of its rival 16777217.

The 137 paths that match neither way are the parts not ported: bypasses, hostiles, storms.

In the 180-day run, the pathfinder asked about access 51 times and closed 27. One search had no route (fleet 6, whose orders in the simulation had already left the game's).

At the 2210.01.01 load, 22 country pairs are closed at level 3. Examples: 16777217 and 16777223 (rivals, closed both ways), the fallen empires 16777226 and 11 to 16777218.

## Left

**Not done, needing engine state the simulation does not model:**

- Ending wars, peace deals, war goals and their use (`using_war_goal`, `is_total_war`, `has_war_goal`), war leaders (`is_war_leader`).
- The war exhaustion's changes, truces made by peace, the AI's diplomatic actions (proposals, accepting pacts, closing borders, rivalries).
- No save of ours has a war, so the war keywords are implemented from the code and the writers but untested on data.

**Approximated** (marked **[I]** above):

- `is_hostile` and `IsFriendlyCached`'s hostility;
- `CanControlAccessFor`'s subject, agreement and primitive rules;
- `CalcIsBorderingSystem` for non-country scopes;
- `CResolutionType::CanBeActive`;
- the system status cache's update times;
- cosmic storms opening the borders (no storms in the simulation);
- `CClaim::IsValid`.

**Not implemented in this area:**

- `relative_power` (`CRelativePowerTrigger`: the AI's fleet, economy and technology power ratings and their level names; 6 hits in the 180-day run, in the ethics);
- `can_declare_war`, `would_join_war`, `has_casus_belli`, `has_claim`, `num_claims_on_system`;
- `opinion_level`, `intel`, `has_intel*`;
- `galactic_community_rank`, `num_council_positions`, `is_permanent_councillor`;
- the espionage keywords;
- `can_access_system` / `has_access_fleet` (`CFleetMovementManager::CalcCanMoveTo`: a path search);
- `agreement_preset`, `any_agreement`, `vassals`, the specialist triggers.
- `trigger:years_passed` (156 hits) now only needs a `TRIGGER_VALUES` entry, but it is not in this area.
