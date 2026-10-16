# The outliner and the alerts (4.5.2)

What the renderer draws of `interface/outliner.gui` and `interface/alerts.gui`, and the rules,
read from the Linux 4.5.2 build (`nm`, `objdump`; addresses below) and the game's files, checked
against the real game's frames (`headless/view.sh`, `gui on`).

**[V]**: read in the game's code or files, or measured in its frames. **[I]**: inferred.

Code: `sim/render/lua/render/windows/outliner.lua` (`extract` on the simulation's thread, from
render.galaxy; `layout` on the render thread, from render.windows), `windows/alerts.lua` (the
alerts' conditions; app.rs `main_screen_items` lays them out), `sim/render/src/outliner.rs`
(LuaData: the extract's view copied between the two runtimes as Galaxy::outliner_view; State:
the tab shown, the groups collapsed, which view shows; the `outliner:` actions; flag_country).

## 1. The window

- **The controller** (`outliner_controller_window`, COutlinerControllerView 0x2ff2cc0) **[V]**:
  `tabbed_outliner_toggle` and `observer_outliner_toggle`. The observer's toggle shows only when
  the local human has no country (Update 0x2ff34c0: the console's `observe`). A view's toggle
  hides it when it shows, else shows it instead of the other (OnToggleTabbedOutliner 0x2ff2fd0,
  OnToggleObserverOutliner 0x2ff3030). Actions `outliner:tabbed`, `outliner:observer`.
- **Its height** (COutlinerListViewBase::InternalUpdate 0x2fedd30) **[V]**: the list's content +
  20 + the list's y (40; the observer's 50), at least `outliner_min_size` (180), at most the screen
  less the window's y (186) and `outliner_window_margin` (193): 521 at 900 lines. Rows past the
  list's bottom are not drawn (the game's list scrolls). Matches the game's bottom edge to a
  pixel or two (2210.01.01 and 2212.07.01).
- **The lists** (CSmoothListbox::GetSize 0x43d5990) **[V]** and **[I, measured]**: a group's
  header is 38 high (`outliner_title_entry_window`), its inner list at (2, 36), member rows 41
  high. The tab's list has `spacing = -1`: groups overlap by one. A group's inner list gives no
  spacing and its rows come 42 apart in the game's frames: spacing 1 here (measured; the
  default's value is not read). Sector groups nest in the Sectors group's inner list the same
  way (two pixels further right).
- **The rearrange button** **[V]** shows only on a tab with colonies or sectors
  (HasPlanetOrSectorGroup 0x2fef000: Overview); drawn at its sprite's 28 x 28 as in the game's
  frame, not the .gui's 20 x 20 **[I]**.

## 2. Tabs (CCountryTabbedOutliner)

| tab | name key | button sprite | groups, as shown |
|---|---|---|---|
| 0 | `outliner_government` (Overview) | GFX_outliner_government_tab_button | (Armies,) Utility Ships, Military Fleets, Starbases, Shipyards, Sectors (, Situations) |
| 1 | `outliner_ships` | GFX_outliner_ships_tab_button | Utility Ships, Military Fleets |
| 2 | `outliner_politics` | GFX_outliner_politics_tab_button | (Observation Posts,) Factions (, Integration) |
| 3 | `outliner_structures` | GFX_outliner_structures_tab_button | Megastructures |

- **Which buttons** (UpdateTabButtons 0x2ff24f0, CalcIsTabEnabled 0x1e00130) **[V]**: Overview and
  Ships always; Politics and Structures once they have members (then they stay). In enum order
  in `tabs_gridbox` (slots 46 x 27). 2212.07.01 has factions: the third button, as in its frame.
- **The active one** (SwitchTab 0x2ff16d0) **[V]**: its sprite in frame 2, the others in frame 1;
  Overview after a load. A click: `outliner:tab:N`.
- **The groups' order** (RegenerateGroups 0x2fedc30, COutlinerSettings::GetSort, SortedMerge
  0x2fffb50) **[V]**: groups are made in EOutLinerGroup order; every tab but Politics reads
  another tab's sort settings, all its groups sort equal and the merge sort reverses them;
  Politics sorts by its own list. The sort runs again each time the tab shows, so the order flips
  with every show: reverse enum order at the first, enum order at the second (the game's frame
  of Overview after a visit to Ships: Sectors, Shipyards, Military Fleets, Utility Ships)
  **[V]** (State::shows counts the shows). Empty groups and disabled ones (Colonies, the arkship
  groups: GetDefaultDisabled) are left out.
- **The badge** (UpdateNotification 0x2fefb60, UpdateTabNotificationCountForTab 0x1e00410)
  **[V]** for the rules, **[I]** for the counts from the save: Overview counts colonies with
  unemployment (+ buildings that can be upgraded: not counted here **[I]**), critical (on red)
  colonies under LOW_PLANET_STABILITY and negative situations; Ships counts fleets that can be
  repaired (+ MIA ones), critical science ships without a leader; "9+" over nine; the critical
  count wins. The game also adds the entries new since the tab was last selected (none after a
  load). Both saves: Overview "1" (Uthab's unemployment), as in the frames.
- **Keys** **[V]**: Ctrl+Q/W/E/R a tab, Ctrl+A/D the previous and next (not bound here).

## 3. Groups and collapsing

- A click on a group's header toggles it (COutlinerGroup::OnToggle 0x2fec3b0: `expanded ^= 1`)
  **[V]**: collapsed, the group is its header alone (38), its count still shown; per group of a
  tab, not saved. `outliner:toggle:<group>@<tab>` (a sector's `sector:ID`).
- **Sectors** (COutlinerGroupSector::UpdateDerived 0x300fc00) **[V]**: a group per sector of the
  country (`outliner_sector_title_entry_window`: the sector icon, its name), then "Frontier
  Sector" (FRONTIER_SECTOR) for colonies in no sector's system (CCountry::GetFrontierColonies);
  the Sectors header counts them. Planets in the country's display order (none set: the
  sector's) **[I]**.
- **Factions** (COutlinerGroupPopFactions::UpdateInternal 0x301eff0) **[V]**: the country's
  factions whose type is shown (type +0xd18), in the module's order (the save's **[I]**).

## 4. Rows (COutlinerMember*::UpdateEntry)

Common **[V]**: the location is SYSTEM_TEXT `$SYSTEM|E$` (teal), IN_FTL `§EIn FTL§!` for a
military fleet between systems; a selected row's background glows (`selected_overlay`); the
leader's level badge is GFX_outliner_leader_level in frame = the level, shown with a leader.

- **Utility ships** (`outliner_member_fleet_civilian_entry_window`, 0x3019610) **[V]**: the
  status icon, the badge (the commander: the leader whose `location = { type = ship id = FLEET }`
  **[I]**), the name plain, the type the first ship's size name (orange: the box's `H`), the
  location. Order: by ship class (construction before science **[I]**), then the owned-fleet
  order.
- **The status icon** (CFleet::GetFleetStatusIconFrame 0x2949d90) **[V]**: combat 6,
  bombardment 10, a colony ship 29/30, an order's own frame (moving 2, survey 4, build 5, colonise
  16, research 18 ...), MIA 11, landing armies 13, repairing 8, docked 3, in orbit 23, idle 1.
  From the save **[I]**: moving (movement state not idle) 2, docked (orbiting a starbase) 3, a
  planet's orbit 23, else 1. Both saves: 3 for all three fleets, as in the frames.
- **Military fleets** (`outliner_member_fleet_entry_window`, 0x30139b0) **[V]**: the name `§T`;
  the size line (BuildFleetTemplateCountString 0x2942a00) `§Y used §!/§Y limit §! (template)`,
  the template's size `§E` when the fleet is under it: "15/50 (15)" = the ships' command points
  (their ship sizes' `size_multiplier`: corvettes 5) / the fleet command limit
  (COMMAND_LIMIT_BASE 50 **[I: its modifiers not summed]**) (the template's `fleet_size`); the
  power `£military_power£ N`, red under the template's full power
  (BuildFleetTemplateOffensivePowerString 0x2942ef0) **[I: a ship short, damaged or of another
  design than the template's stands for "under"]**; the status grid (`fleet_status_entry`,
  GFX_outliner_fleet_status: 1 repair, 2 upgrade; from x 186, y 20 leftwards): can repair (a
  damaged ship **[I]**), can upgrade (a ship with an `upgrade` design **[I]**).
- **Starbases and Shipyards** (`outliner_member_starbase_entry_window`, 0x30266f0) **[V]**: the
  type icon GFX_starbase_outliner in the station's ship size's `icon_frame` (starport 2), the name
  the station ship's (`§E`, "Ithni Zerak A Station"), the starbase's type name ("Shipyard"),
  the system, the power always `§Y`. Shipyards are the starbases with a shipyard module (the
  game: those with a construction queue **[I]**); the others above outposts are Starbases.
- **Colonies** (`outliner_member_planet_entry_window`, 0x300a660) **[V]**: in the default display
  mode the planet's portrait (its class's `icon`, a frame of the GFX_planet_type sheet: a sprite
  set at run time shows its own default frame) and the designation's name; the name `§E`
  (`§R` occupied) with `£sector_capital£` before a sector capital's (the sector's
  `local_capital`); the governor's badge (GetPlanetGovernanceLevel: the leader at
  `location = { type = planet id = COLONY }` **[I]**); the status icons
  (COutlinerPlanetStatusController 0x3495e80; `planet_or_starbase_status_entry`, frame =
  condition + 1, at most 5, leftwards from x 238 **[I: by the frame]**): 1 a free building slot
  (a zone with fewer buildings than its `max_buildings`, else
  DEFAULT_MAX_PLANET_BUILDINGS_PER_ZONE **[I]**: queued buildings and `districts_per_building` not
  counted), 2 a blocker worth clearing (ClearingBlockersIsBeneficial 0x28d6550: a blocker (its
  category's `blocker = yes`) the country can clear (its `prerequisites`), and the colony's
  growth capped: the largest species' pops at least `carry_cap_per_free_district` x the free
  districts (planet_size + the deposits' planet_max_districts_add, less the districts' levels) +
  `free_housing`, or every district built **[I: the growth curve's terms and other district
  modifiers left out]**; 2210.01.01: 2695 < 2788, no; 2212.07.01: 2767 >= 2682, yes, as in the
  frames), 3 a building that can be upgraded (an `upgrades` target whose prerequisites the
  country has **[I: potential and allow not evaluated]**), 6 unemployment of POP_BULK_UNIT_SIZE (100) or more (`unemploy_pop`), 7 unemployed
  and civilians of POP_OUTLINER_CIVILIAN_WARNING (500) or more, 8 overcrowded (`free_housing` <
  0), 11 stability under LOW_PLANET_STABILITY.
- **Factions** (`outliner_member_pop_faction_entry_window`, 0x3022520) **[V]**: the name, the
  type's icon (GFX_faction_icon_<type>), APPROVAL_OF_FACTION with the approval in percent (its
  £mod_faction_approval£ icon not drawn: no sprite of that name),
  `§G` at POP_FACTION_APPROVAL_HIGH (0.6) or over, `§R` under _LOW (0.4), else `§Y`
  (CPopFaction::GetApprovalColor 0x1e8df10), the members (the save's `last_month_pops` **[I]**).
  The influence it gives (GAIN_FROM_FACTION: a resource table) is not drawn.

## 5. The observer's list (CObserverOutliner, CObserverOutlinerGroupEmpires 0x3029ac0)

- In observe mode the tabs show and are empty (the observer has no country), as in the game's
  frame; the eye toggle opens `observer_window_outliner` ("Observer", the unobserve button).
- Groups **[V]**: Minor Countries, Fallen Empires, AI Countries, Player Countries (reverse enum);
  the countries kept: alive, of a type with `observable = yes` **[I: type +0x4d bit 4]**;
  fallen ones by their type's `fallen_empire`/`awakened_fallen_empire` **[I]**; an observer has
  no player countries. By economy power, the highest first (`economy_power`) **[V]**.
- Rows (`observer_outliner_country_window`, 56 high, 0x302c7d0) **[V]**: the flag (app.rs
  composes it: the row's path carries `@COUNTRY`), the name, the federation's name, `might` the
  economy power (COUNTRY_ECON_POWER), the fleet power (SI_NUMBER, one decimal from 1000:
  "407.0K"), the pops (`num_sapient_pops` **[I]**); the
  war icons not drawn (no wars here).

## 6. Alerts (CAlertManager)

- **Evaluation** (Update 0x1df72d0) **[V]**: one alert a frame, round robin over the 66 of the
  ALERT enum (common/alerts.txt's order); a sweep takes 66 frames, so the game's first frames
  after a load show only the alerts reached so far (2210.01.01's first frame: four; after a few
  frames: six). The renderer shows the settled set.
- **Order** (AddAlert 0x1dffc80) **[V]**: by the alert type's priority (HIGH, MEDIUM, LOW), then
  the order added (after a load, the enum's). A banner the code sets (first contact LOW,
  resource shortage HIGH) changes the banner, not the order.
- **Place** **[V]**: from (200, 30), 55 x 72 apart, five a row (alerts.gui positionTypes); a new
  one falls in from y -64 (not animated here).
- **Conditions drawn** (UpdateAlert 0x1df0170 and the functions it calls) **[V]** for the rules,
  **[I]** for the save's fields:

| alert | condition |
|---|---|
| physics/society/engineering research | the area has nothing being researched (no `<area>_queue`) |
| low_stability | a colony under LOW_PLANET_STABILITY (25) |
| resource_shortage (banner HIGH) | a resource with no stock and a negative monthly balance |
| unlock_tradition | unity >= 300 + (8 x adopted) ^ 1.8 (no second term with none adopted), x (1 + 0.002 x max(0, empire_size - EMPIRE_SIZE_BASE 100)) (CTraditionType::CalcCost 0x20eeeb0; the admin cap and tradition cost modifiers not summed **[I]**) |
| first_contact_stage_done (banner LOW) | a first contact in progress with its stage's event pending |
| unspent_leader_trait_points | a leader of the country with `available_trait` |
| unassigned_leader | a leader not the ruler, not an envoy, with no location, not a candidate of the recruitment pool (`standard_leader_module` leaders) |
| available_council_agenda | no agenda chosen (the game: and one available) |
| available_council_position | `picked_council_types` fewer than `unlocked_civic_council_slots` |
| council_agenda_ready_for_activation | progress >= 7000 x (1 + 0.001 x max(0, empire_size - 100)) (CCouncilAgenda::GetCost 0x2323c30): 7008 >= 7000 in both saves |
| open_council_position | a council position without a leader |

- Not drawn **[V: the rules are known]**: negative income (its define is missing: never shows),
  timed projects, fleet and army combat, hostiles in a system, capped resources, war goals,
  ascension perks, civics, relics, site events, declining pops, the federation's, espionage's,
  MIA fleets', DLC mechanics' (shroud, astral rifts, cycles, necrophage, space fauna).
- The round icons right of the alerts in 2212.07.01's frame (a pie, a bust with a plus, three
  times) are messages (CMessageSystem: the save's `message` entries MESSAGE_FACTION_SUPREMACIST
  and MESSAGE_GAINED_TRAIT), not alerts.

## 7. Compared (game left, renderer right: view.sh and stellar-render with the same command files)

- 2210.01.01 and 2212.07.01, Overview: every group, row, icon, number and colour the same, the
  window's bottom within two pixels. Differences: the 2212 Typhoon's power, 172 in the game (it
  recomputes NCombatRules::CalcMilitaryPower after the commander's level-up) against the save's
  cached 168.5 here (CShip::CalcMilitaryPower: the ships' hit points, armor, shields and damage
  a day with their modifiers: not computed).
- Observe (2210.01.01): the tabbed outliner empty at 180 high with the eye toggle, the same.
- Alerts (the game's settled frames, the third `frame` after the load): 2210.01.01 and 2212.07.01
  the same six in the same places (2212.07.01's messages aside).
- Clicks (`click X Y`, the same command files; in the game after a settling `frame`, `tick 5`
  between a click and a move, `tick 120` after `observe`), 2212.07.01: the Ships tab, Overview
  again (its order flipped) with Sectors collapsed, and the observer's list: the same, but for
  the numbers the game computes live (the Typhoon's 172; economy power and pops a few units off
  the save's) and the game's last row, half drawn under its list's edge with a scroll bar (rows
  that do not fit are left out here).
