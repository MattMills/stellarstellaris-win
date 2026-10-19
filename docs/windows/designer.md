# The ship designer and the combat view

The ship designer (`interface/ship_designer.gui`, CShipDesigner / CShipDesignerBase) and the combat
view (`interface/combat_view.gui`, CCombatView), as the 4.5.2 Linux build fills them, and how the
renderer does it: `sim/render/lua/render/windows/designer.lua`, `combat.lua` (data and layout),
`sim/render/src/designer.rs` (state, the two runtimes, the ship models), the 3D view as an inset
(`scene::Inset`, `render.rs`). Read in the game's code **[V]** (addresses: the Linux build), or
inferred **[I]**. The combat stats window (`combat_stats_view.gui`, opened from a combat message)
is read (below) but not drawn.

## Opening them, in both

`open_designer` is one command of the protocol (docs/render.md section 9), in the game's headless
driver (`headless/headless.c`) and the renderer (`engine.rs`):

| command | the game (headless.c) | the renderer |
|---|---|---|
| `open_designer` | `CShipDesignerBase::Show()` on `CInGameIdler::AccessShipDesigner()` (idler +0xd98), as the fleet manager's tab does | the designer open, no design loaded |
| `open_designer design ID` | then CShipDesignEntry::Click's work: `LoadDesign(TPdxRef<CShipDesign> ID, owner 0, false)` and the five popups' refresh (designer +0x1a58..+0x1a78, vtable +0x100) | the design loaded |
| `open_designer combat [FLEET]` | the fleet selected: `CInGameIdler::Select` of its CSelectable (CFleet +0x18), as a click; without FLEET the first fleet (by database slot) with `CFleet::HasCombat` | `select fleet` of the first fleet (by id) whose save block has a `combat.in_combat_with` |
| `open_designer close` | `CShipDesignerBase::Hide`, `CCombatView::Hide` (idler +0xb50) | closed, a selected fleet deselected |

The reply names the fleet: `ok open_designer combat 261`. The designer's close button, its
ESCAPE shortcut and the fleet manager's tab close it; a design in the list loads it
(`designer:design:ID`).

Selecting a fleet shows the combat view instead of the fleet view when the fleet is in combat
**[V]** (CInGameIdler::ShowFleetView 0x1c89110: CFleet::HasCombat, then CCombatView's Show,
vtable +0x38); CCombatView::Update lists the *selected* fleets (idler +0xa80, type 1) in combat, so
a fleet must be selected, not merely shown. The renderer: `app.rs` window_items asks
`designer::in_combat` and leaves fleet_view out for such a fleet.

## The ship designer

### What shows **[V]** (CShipDesignerBase::Setup 0x318e2e0, Show 0x3190300, Update 0x3192150, UpdateInfo 0x3193010, UpdateControlsWindow 0x3194450)

- Always: `fleet_manager_tab`, `ship_designer_tab_active`, `creature_designer_tab_inactive` (the
  other two tabs StayHidden), `3d_view` (the viewer), `design_name` = `SHIP_DESIGNER_COUNTRY`,
  `auto_design` down iff the country's `ship_design_collection` has no `auto_gen_design = no`
  (GetAutoGenerateShipDesigns), its label, `designs_list`, `close`; `blocker` and
  `component_paint_help_text` hidden (no popup, no component being painted).
- Opened: no design loaded (Show clears the data when the owner changes): `ship_label` =
  `SHIP_NAME_STATS` ("Specifications"), `controls` and `info/content` hidden, the help texts
  hidden, no sections; the `info` box where the .gui has it (244 x 455 at (-174, 70) of the upper
  right).
- A design loaded: `ship_label` = `LONG_SHIPCLASS_NAME` ("$NAME$-class $SIZE$", the size's
  capitalised family name: `<size>_cap` else `<size>` **[I]**); `controls` shown (the design's name
  in the rename box, `choose_role` with the role's name, the bottom buttons, `upgrade_ship_components`
  down iff the design's `upgrade_ship_components = yes`); `bioship_stage` and its spinner hidden (not
  a growth-stage size); the info box at `info_mecship_pos` (1098, 40) with
  `info_background_mecship_size` 244 x 485 (SetInfoPosAndSize "mecship"); `weapons_help_text` iff
  the design has weapon slots and none filled, `utilities_help_text` the same for utilities;
  `cloaking_values` only with its DLC (hidden in the 2210 save's game).

### The designs list **[V]** (UpdateDesignsList 0x3191260, GetAllDesignsToDisplay 0x317f380)

`new_ship_design_entry` ("New Design") first; then the country's designs (its
`ship_design_collection`, the ids with their generation bits as the store's keys) that it can
build: a designable ship size (`is_designable` not `no`) whose `prerequisites` it has researched
(**[I]**: CanCountryBuildPotential's `potential_country` triggers are not evaluated); auto-generated
designs are listed. Sorted (stable) by the size's definition order (common/ship_sizes in file
order); a `ship_design_header_entry` (the size's capitalised name) where the size changes. Each
`ship_design_entry`: its name (Y), its 3D view (the render target: an inset with the design's
model, smaller than the main view **[I]**), `auto_gen` for an auto-generated design
(`AUTO_GENERATED_BEST` "Auto-Generated" with auto-generation on, else `AUTO_GENERATED_STANDARD`),
`selected` (the orange glow) for the loaded design, `delete` hidden (mouse over only). Heights:
the .gui's (90, 18, 91), no spacing. 2210.01.01: New Design, Corvette: Ripjaw Angler, Defense
Platform: Buoyant Barnacle, as the game.

### The stats **[V]** (SetupInfo 0x318c590, UpdateStat 0x318d5e0, CalcStat 0x31971e0)

From `first_stat_position` (-72, 55) of `info/content`, a `value_title` 25 high, a `value_line` 22:
Production; Build Time, Upkeep, Cost; an empty title; Ship Stats; Ship Size, Naval Capacity Usage,
Power, Hull Points, Armor, Shields, Evasion, Speed, Damage, Sensor Range (growth threshold, growth
speed and rarity only for bio and creature sizes). A value is the stat's `<key>_VALUE`
localisation with VALUE given already formatted (two decimals; size and sensor none), so its
digits flag does not round it ("60.00"); Evasion min(evasion, the cap) with one decimal and %;
Power a whole number with its sign, green or red; Cost and Upkeep each resource's text icon and
amount (CResourceTable::BuildString). Sensor Range's label is `SHIP_STAT_SENSOR_RANGE` without its
`$VALUE$`.

The numbers here (designer.lua `stats`) **[I]**: the ship size's (max_hitpoints, max_speed,
base_buildtime, size_multiplier, its `modifier`, its upkeep), the sections' and components' (the
scripted variables of their own file over the global ones; `modifier` blocks: ship_armor_add,
ship_shield_add, ship_evasion_add, ship_reactor_power_mult ...; power; cost and upkeep), the
weapons' `weapon_components.csv` (the mean damage x accuracy over the cooldown and the mean
wind-up, in days). The country's modifiers are not applied. Against the game's frame of the Ripjaw
Angler (2210.01.01):

| stat | game | here |
|---|---|---|
| Build Time, Cost | 60.00, 110.00 alloys | the same |
| Ship Size, Naval Capacity, Power | 5, 5.00, +35 | the same |
| Hull, Armor, Shields | 200.00, 200.00, 100.00 | the same |
| Evasion, Speed, Damage | 62.3%, 166.22, 8.46 | 60.0%, 160.00, 8.15: the game's are x 1.0389 (a modifier not read) |
| Upkeep | 1.48 energy, 0.57 alloys | 1.55, 0.60: the game's x 0.955 |

### Sections, slots, required components **[V]** (CShipDesigner::UpdateSections 0x317fad0, CSectionInstanceEntry 0x3180790, UpdateRequiredComponents 0x3194130)

A `section_instance_entry` (192 wide) per section slot of the size, in definition order, in the
`sections` box (spacing 10, centred). The section's name (its template key localised:
CORVETTE_MID_S3 "Interceptor") is `change_section`'s text, `NO_SECTION` with none. The slots:
`weapon_slots` from the top and `utility_slots` from the bottom (LOWER_LEFT), 56 a cell,
max(3, ceil(n / 3)) columns centred on the entry's mask column, one `component_slot` per slot of
the section template in its order (its `component_slot` blocks, then the
`small/medium/large/aux_utility_slots` counts: SMALL_UTILITY_1 ...). A slot's frame of
GFX_ship_designer_slot: weapon size + 4, utility size (NComponentUtils::GetComponentSlotIconFrame);
the size enum by the texture's frames **[I]**: small 0, medium 1, large 2, torpedo 3, extra large 4,
titanic 5, planet killer 6, aux 11. The placed component's icon (`icon`, `icon_frame`). Under each
grid its background GFX_ship_designer_grid_<cols>_2 (two rows of cells) **[I: by the frame]**. The
required components: a `required_component_entry` (60 high) per `required_component_set` of the
size, in a column at `required_slots_position` (945, 374) centred on y, the chosen component's
icon. The masks are for bioships only.

### The 3D view **[V]** / **[I]**

The viewer is `3d_view` sized `ship_designer_3d_view_size` (740 x 584). gfx/worldgfx/ship_designer.txt
gives its world: the background `galaxy_background` gfx/map/sky_rim.dds (a YCoCg cube), its
lights and environment map. Here (designer.rs `fill_insets`) the design's model is drawn as a ship
in a system is (system.lua `design_model`: the culture's frame entity, the sections at its
locators, the turrets), from its side, the bow to the right, 14 degrees above, filling the width
**[I: matched to the frame by eye: yaw -75]**, with the ship designer world's camera lights and
environment, the sky behind it. Without a design the sky alone shows, as the game's. Not matched:
the sky's orientation (another part of the cube faces the camera), the game's post effects in the
viewer (its bloom and lens flare: the hull here is cooler and flatter).

The inset (`scene::Inset`): a sprite item of kind "inset" marks a 3D view's place in the GUI
(`add_gui` pushes an empty batch there); the scene's builder fills its view, lights, meshes and
sky; `render.rs` draws it in the GUI pass at that batch, in its rectangle (viewport and scissor),
with its own view uniform, its sky (an LDR sky pipeline, gamma-encoded for a target that is not
sRGB: sky.wgsl `flags.z`) and its meshes, depth tested in the GUI pass's own depth (the GUI's
quads write none).

## The creature designer (the Space Fauna tab) **[V]** / **[I]**

The RE notes are in `/root/re452/cd/NOTES.md` on 10.5.0.6. The game install on 10.5.0.24 has no
Grand Archive DLC, so the real game cannot show this mode there. Everything below comes from the
binary and the files, not from the game's frames.

**The window.** The game builds a second instance of `ship_designer.gui`: `CCreatureDesigner`,
type 1, top-bar view 0xd, at `CInGameIdler+0xda0`. Each tab hides one window and shows the other
(Setup's handlers 0x31a67b0 and 0x31a68a0). Here it is one window with a mode (`ui.mode`). The
code is in `lua/render/windows/creature.lua`, called from designer.lua.

In creature mode:
- the creature tabs show active and the ship tabs inactive;
- the title is `CREATURE_DESIGNER` (GetShipDesignerTypeKey 0x3191120);
- `3d_view_creature_designer` replaces `3d_view`;
- the paint help text is `CREATURE_DESIGN_RIGHT_CLICK_TO_CANCEL_MUTATION_PAINT`.

Opening a design whose stage-0 size has `is_space_fauna_ship` switches to creature mode
(OpenDesigner 0x319c3e0, by GetDesignerType). The tab is enabled only for a country with the game
rule `can_use_artificial_breeding` (tech_alien_cloning). **[I]** The RE found no code that gates
the tab on this rule.

**The list.** It shows the country's designs whose stage-0 size has `is_space_fauna_ship`; the
ship mode shows the others (GetAllDesignsToDisplay 0x2c93650). A creature design is listed when
the country has the culled DNA of its size's `ship_category`. That is CanCountryBuildPotential,
which reads the size's `potential_country` and `has_dna`. **[I]** Its prerequisites are not checked.

**A design** is its size's creature designer template plus the mutations on the six `ANY_` slots
of its `mutation_section` (MUTATION_SECTION_NAME, slot `mutations`).
- The template is the first global design with `creature_designer_template = yes` whose stage-0
  size is that size, in file order (GetCreatureDesignerTemplate 0x24a8f20).
- Each change rebuilds the body from the template (RefreshDesignAndApplyMutationsEffects 0x2c93440).
- Each mutation puts its component for the size's `mutation_components_size` on its slot
  (GetComponentForShipSize 0x1db4e00).
- `component_slot_size_to_disable` removes the components of that slot size from the other
  sections.
- FixRequired keeps the template's required components that exist. Each required set with none
  gets the newest component of the set the country has researched. **[I]** The choice. The 4.5.2
  amoeba template's `BIO_PROPULSION_1_CORVETTE` is not a component.

**New Design** opens the `selector` (CCreatureSelector::Update 0x31a08e0).
- It shows a `selector_item` per ship category in the country's
  `grand_archive_country_module.culled_dna_list` (rarity not 4), titled with the category's name.
  **[I]** The key of the block holding that list: the extract reads `culled_dna_list` from any of
  the country's blocks.
- A category needs a designable fauna size with a template. Its first such size is used.
- A click loads a copy of that template with an empty name.
- **[I]** The item's 3D `ship_design_icon` is not drawn.

**The design area.** One `creature_mutations_instance_entry` sits centred in the `sections` box
(UpdateMutations 0x2c94000). It holds:
- `change_size_button` (PICK_CREATURE_SIZE): a selector of the growth family's sizes. The family is
  the templates linked by `upgrades_to`, both ways (GetShipSizesVariantsFromDesignerTemplates
  0x1f67da0). A click loads the country's design of that size, preferring one with the same name,
  with the current mutations and name. **[I]** With no such design it loads the template. Owned
  ships are not counted.
- `fixed_components_slots`: the template's other sections, read only. Weapons fill the first row
  and utilities the second, centred.
- `mutation_slots`: all six slots, three to a row.
  - Slots past the country's count are disabled (UpdateInternalData 0x2c94ed0). The count is
    mutation_slots_add; **[I]** only the technologies' modifier is counted (tech_controlled_mutations
    +3, _2 +3).
  - The button shows frame 2 for a unique mutation, else 1. Its sprite comes from the NInterface
    defines CREATURE_DESIGNER_MUTATION_SLOT(_LOCKED)_ICON, which are empty in these files, so the
    slot keeps its own sprite.
  - The icon is the mutation component's.

**The mutation picker** is `component_select_window` (ShowMutationSelectDialog 0x2c92e00,
UpdateElementList 0x2c968a0). It opens from a slot click.
- Its labels are SELECT_MUTATION, SELECT_MUTATION_DESC and CREATURE_MUTATIONS_FILTER_OBSOLETE.
- The mutations are grouped by type (offensive, defensive, aux), each under a
  `creature_mutation_type_entry` titled `<type>_mutation_type`. Clicking a header toggles its group.
- A mutation is listed when its first component's prerequisites are researched (CanBuildComponent).
  **[I]** The component's potential is not evaluated.
- With the filter on, a mutation is hidden when a later one in its `upgrades_to` chain is usable
  (HasBetterElement 0x2c96f80).
- A unique mutation shows `unique_mutation_icon`, with the CREATURE_DESIGNER_MUTATION_IS_UNIQUE
  tooltip.

**Clicks.**
- A mutation selects it for painting (ItemClicked 0x2c96f50).
- A slot clicked while painting gets the mutation. Painting a unique mutation that is already on
  another slot is refused (HasUniqueMutation 0x1f689c0). A drag across slots paints each one.
- A right click cancels painting, or clears the slot when not painting (0x2c956a0).
- Fill Empty puts the mutation on every empty slot, without the unique or locked checks
  (0x2c93300).
- Clear removes all mutations.
- Save builds every size of the growth family with the same name and mutations, one
  CCreateOrUpdateShipDesignCommand each (BuildAllCreatureDesignsVariants 0x1f682a0). Each saved
  variant replaces the country's design of the same size and name. Here this is
  `designer_commands.save_many`.

**Checked by script** (`--script`, 10.5.0.24). The test saves come from
`sim/render/tools/fauna_fixture.py`: the 2210.01.01 save with tech_alien_cloning, both mutation
techs, two unique mutation techs, and amoeba, tiyanki and voidworm DNA.
- The tab and the three categories.
- An amoeba: its template's body and fixed components.
- The mutation picker: groups, toggling, the unique mark.
- Painting by click and by drag; a right click; the unique refusal.
- Typing a name, then Save: designs 33554589 (`space_amoeba`, the `_SMALL` components) and
  33554590 (`space_amoeba_mother`, the `_LARGE` components) in the simulation.
- The size picker, which loads the mother design.
- Back on the Ship Designer tab, the fauna designs are not listed.
- With one mutation tech, slots 4 to 6 are locked.

## The combat view **[V]** (CCombatView::Update 0x2bf3c40, UpdateCombatantEntry 0x2bf3950, CCombatViewFleetEntry::UpdateEntry 0x2bf5a70, CCombatViewShipEntry::UpdateEntry 0x2bfa660, UpdateCombatStats 0x2bf4870)

- The fleets: the selected fleet, then every fleet it is in combat with. A reference country: the
  controller most aligned with the player (GetAlignmentToCountryCached, ties to the lower id); here
  **[I]** the player, then empires, then the others. The fleets whose controller is hostile to it on
  the right, the others on the left; here **[I]** the fleets fighting a reference fleet.
- A `combat_view_fleet_entry` per fleet: its name (GetLocalNamePersistent 0x292a6d0: with
  communications the fleet's name; without, the country type's `pre_communications_fleet_name`
  (Space Amoeba: NO_COMMUNICATIONS_AMOEBA "Alien Vessels"), a station's NO_COMMUNICATIONS_STATION,
  else NO_COMMUNICATIONS_FLEET, `_XENOPHOBE` "Alien Menace" for a xenophobe player); the owner's
  flag (drawn here as the sprite's own frame **[I]**); `emergency_ftl` for the player's own fleets;
  `orders_hero_ship` hidden; its ships from y 140, the entry as high as they reach.
- A `combat_view_ship_entry` (50 high) per ship: its name (with communications the size's and the
  ship's names and "$CLASS$-class"; without, the size's `pre_communications_name` or
  NO_COMMUNICATIONS_VESSEL(_XENOPHOBE)), the hull, armor and shield rings at round(% x 100) (armor
  and shields hidden without any), the ship class icon (GetShipClassIconFrameFromSize: the size's
  `ship_class_icon_frame`, else by class **[I]**), `inspect` disabled before contact (the game greys it
  with its shader: not done here), `destroyed`/`disengaged` hidden. The rings are turned 180 degrees about (41, -37) in the
  .gui: drawn over (41 - w, 37 - h) .. (41, 37), not turned **[I: by the frame]**.
- The bar (`progress`, a progressbarType): the left side's share of both sides' hull points,
  round(100 L / (L + R)) in 1..100; its first texture (green) to the share, its second (red) past it
  (the game's progress.shader cuts them; here the green is squeezed over the red **[I]**); the glow
  at its .gui x + frame x 0.01 x the bar's width.
- The bottom: each side's damage dealt to hull, armor and shields (whole numbers) and its hit
  ratio ("0%" with no shots); a save keeps no combat stats in its fleets' `fleet_stats` **[I]**, so 0.
- The lists clip their entries **[I]**: what starts below the list's bottom is dropped, a
  background crossing it is cut.

2210.01.01 (`open_designer combat`: fleet 261, five Space Amoeba ships, against fleet 33554951,
a Yv'Zorak science ship; the player xenophobe without communications): left "Alien Menace" with one
ship "Alien Menace" (the science class icon), right "Alien Vessels" with five; the bar 16% green;
0 damage, 0%. As the game's frame.

## The combat stats window (combat_stats_view.gui, CCombatStatsView) — read, not drawn

Opened from a combat message (ShowWithMessage 0x2bed930): a won/lost background and title
(`COMBAT_WON` / `COMBAT_LOST`), `combat_location` (the system and date), `our_leader` /
`their_leader` (portrait, name, skill, experience, traits), `fleets_left` / `fleets_right` (flag,
fleet name, ships by class, ships lost), two panels of up to seven stats (damage efficiency, point
defence, hit and evasion ratios).

## Comparisons made (10.5.0.24, 2210.01.01, 1600 x 900; game left, renderer right)

The same command file on both (`headless/view.sh --script`, `stellar-render --script`):
`open_designer`, `open_designer design 2207` (the Ripjaw Angler), `open_designer combat`. The
side-by-sides: `code_working/tmp_sym/render3d/parity/windows/` (designer_empty.png, designer_2207.png, combat_2210.png).

- Designer, no design: the same frame, list, tabs, title, info box, sky in the view.
- Designer, Ripjaw Angler: the same layout, texts, slots, icons and required components; the
  numbers as the table above; the ship from the same side.
- Combat: the same sides, names, entries, icons, bar and stats.

## The buttons

What a click does, as the game's handlers do it (CShipDesignerBase::Setup's observers
0x318e2e0, the popups' views); `designer:*` actions, `designer.rs` `act` (the window's close, the
fleet manager tab, a design in the list, the combat view's focus) and `designer.lua` `act` (the
window's own state: the designs under modification, as SDataUnderModification keeps them, and its
popups). What changes the world goes to the simulation's runtime between its days
(`designer_commands.lua` through `Clock::query`, the simulation started first as a view's command
starts it), through the engine's own ship designer (`engine.ai.designer`: `generate`, the AI's
CreateShipDesign; `execute_create`, CCreateOrUpdateShipDesignCommand; `buildable`, the components
it accepts, potential triggers evaluated). After a change the window's data are read again from
the simulation's world, so a saved design is in the simulation's designs (its fleets, the AI, a
save written from it).

| element | the game | here |
|---|---|---|
| close (X), Escape | Hide; ESCAPE closes the innermost popup first (each popup's close has the shortcut) | wired: a popup closes first, then the window |
| fleet_manager_tab | the Fleet Manager's view | wired (`view:fleet_manager`, the designer closed) |
| creature_designer_tab_inactive | the creature designer (disabled without artificial breeding) | wired: the Space Fauna mode (see The creature designer); disabled unless the country has the game rule `can_use_artificial_breeding` (tech_alien_cloning) [I]; the ship tab goes back |
| auto_design | ToggleAutoDesign: the country's auto-generation of designs | wired, in the simulation (`ship_design_collection.auto_gen_design`); the list's tag becomes "Auto" |
| a design in the list | CShipDesignEntry::Click: LoadDesign | wired |
| new_ship_design_entry | ShowShipSizeSelectDialog: the `selector` of sizes | wired: a selector_item per designable size the country can build, three a row |
| a size | CSelectorItemShipSize::OnClick (0x31a40a0): a design of the size with empty growth stages | wired: no sections ("No Section!", "Select a Section"), the best required components and a name from the name list, from the simulation [I] |
| delete (an entry's) | Delete -> confirmation -> ConfirmedDelete (CRemoveShipDesignCommand) | wired in the simulation (the design out of the country's list): shown on the entry under the mouse, its click opens `delete_cancel_popup_window` (Agree deletes; Cancel, close or Escape keep it) |
| change_section | ShowSectionSelectDialog: section_select_window | wired: the sections of the size that fit the slot and the country has researched, two a row, their slots by size; a click puts it on the slot (CSectionSelector::ItemClicked: the components of the slots it shares kept [I]) |
| a component slot | ShowComponentSelectDialog: component_select_window | wired: over the designs list [I: its place], the components the simulation says the country can build on the size (one per component set, the newest [I]), the slot size filter and the obsolete filter (check boxes), the slot's component highlighted; a click puts it on the slot |
| apply_on_empty (Fill Empty) | ApplySelectedElementOnAllEmptySlots | wired: the component chosen on every empty slot it fits |
| a required component (show_templates_button) | its entry's list of the set's components | wired: leftward of the entry, a click sets it (SetRequiredComponent) |
| randomize_name | RandomizeName | wired: a name of the size from the country's name list (the simulation's `class_name`) |
| rename_box (typing) | the design's name | wired: a click edits it (a caret, the keys the empire creator's text fields take, backspace), Return or a click elsewhere keeps it, Escape drops it; saved as a literal name (`name = { key = ... literal = yes }`) |
| choose_role | CShipRoleSelectionView: the size's roles | wired: `select_ship_role` with a ship_role_entry each (the design's selected); a role makes the design anew for it (GenerateDesignOfRole: the AI designer's design of the role) |
| clear_button | ClearDesignComponents | wired: the sections' components cleared [I: the sections and required components kept] |
| complete_button (auto-best) | Finish | wired: every empty section and slot filled with the AI designer's choice for the size and role [I] |
| save_button | Save -> ConfirmedSave (CCreateOrUpdateShipDesignCommand); an auto-generated design asks first (`rename_autogen`) | wired, in the simulation: the design added to the country (its base design leaves the list: the game replaces the design of the same name [I: fleet templates not retrofitted]); an auto-generated one through `rename_autogen` (Save; its randomize button; close: nothing saved) |
| upgrade_ship_components | AutoUpgradeComponents: the design's flag | wired (saved with the design) |
| bioship stage spinner | a growth stage | not drawn (bioships only) |
| 3d_view | its click observer (the view turned [I]) | wired: a drag that starts on the view turns the ship (0.01 rad a pixel across, 0.005 down, the pitch held to -0.8..1.2) [I: the rates]; the turn stays for the next design |
| right click on a slot | ClearSlot | wired: the slot's component removed |
| painting | a component chosen in the selector stays on the cursor: a click on a slot puts it there, the slots it fits framed, the help text shown; a right click or Escape ends it | wired: a click per slot, or a drag with the button held across the slots (each one passed over painted) |
| the lists | smoothListBoxes: the wheel scrolls | wired: the designs list, the component selector's and the section selector's, 45 pixels a notch [I] |
| disabled frames | complete and save disabled when the design cannot be saved (IsValidToSaveForCountry) | wired: save disabled unless every section slot and required component set is filled and the name is not empty; complete disabled unless the first section has slots; choose_role without roles; the creature designer's tab always [I: the checks] |

The combat view:

| element | the game | here |
|---|---|---|
| close (X), Escape | Hide | wired: the selection cleared (which shows it) |
| focus_on | OnClickFocus: the camera to the combat | wired: the fleet's system entered, the fleet followed [I] |
| a ship's inspect | CCombatViewShipEntry::OnClickInspect: the ship view; disabled before contact | wired (`fleet:ship:ID`, the fleet windows' ship view) when the ship's owner is in contact; disabled (its frame) before |
| emergency_ftl | EmergencyFTL (the player's fleets): CEmergencyFTLCommand after COMBAT_BASE_DAYS_UNTIL_EMERGENCY_FTL days of combat | wired (`designer:combat_eftl:FLEET`): enabled after 14 days of the fleet's combat (x (1 + ship_emergency_ftl_min_days_mult)), its tooltip EMERGENCY_FTL_DESC or the days left (EMERGENCY_FTL_DAYS_LEFT); in the simulation (`engine.fleets.combat.emergency_ftl`): each ship lost at 5%, else damaged at 25% (its hull down by up to 75%), the fleet out of every combat list, at its capital system and ordered back to its starbase [I: the game sends it MIA for the travel] |
| owner flag | (the country) | wired: the owner's flag when it is known (the world's country flag); the blank frame before contact |
| the ship lists | smoothListBoxes: the wheel scrolls | wired: the wheel over a side scrolls it, the list clipped to its box |
| Damage Output | the combat's damage by type (hull, armor, shields) and hit chance | wired from the engine's combat (`engine.fleets.combat.fleet_stats`, tallied per shot); the 2210.01.01 save's amoebas close on the science ship (the engine's combat movement, docs/windows/fleet.md) and fire within the first 16 days: 164 hull, 199 armor, 100 shields, 70% by 2210.01.17 |
| the rings | the hull, armor and shield rings, `rotation = 3.14159` | drawn turned half a turn (a GUI sprite's `flip`: its texture's corners swapped) |
| orders_hero_ship | a hero ship's actions in combat (a ship size with `hero_ship`, a combat computer that unlocks it) | hidden: no hero ship in the saves here (Nomads and Biogenesis ship sizes) |
| the fleet view | (the combat view instead while the fleet fights) | the selected fleet's fleet view is not drawn under the combat view |

Checked in a real window (the windowed renderer under Xvfb on 10.5.0.24, clicks by xdotool, the
2210.01.01 save loaded from Load Game): the left bar's Fleet Manager, its Ship Designer tab, a
design, a slot's component selector (the components the simulation allows: Small Red Laser,
Nuclear Missiles, Small Mass Driver), a component on the slot (the stats changed), the wheel over
the list, Escape (the popup first), the required component's list and a choice, Auto-upgrade,
Clear, Randomize ("Stingray"), the role selection and Escape, Auto-Complete, Save and the
`rename_autogen` Save (a design 33554589 in the simulation), Auto-generate off (the list's
"Auto"), Delete (the design out of the simulation's list), New Design (a corvette, "Sneaking
Shrimp", no section), the close button. Scripted (`--script`, the same clicks): New Design -> a
section -> Auto-Complete -> a role -> Save (a new design in the simulation, listed); the combat
view's inspect (inert before contact), focus (system 239, the fleet followed) and close. A Lua
error in the designer stays in it: the other windows go on drawing (`windows: ...` logged).

## Not done

- Stats: the country's modifiers (speed, evasion, damage, upkeep), the role's.
- The creature designer: the category items' 3D icons, federation and galactic community owners
  (the federation view's Space Fauna button), owned ships in the size picker, and a comparison with
  the game (needs the Grand Archive DLC on the test box).
- The combat view's hero ship orders (no hero ship to check them on); emergency FTL's MIA travel
  (the fleet lands at once).
- The combat stats window.
- The windows cannot yet be opened by clicking in the game's frames (render-controls' input is
  merged after this: the designer opens from the fleet manager, which another session draws).
