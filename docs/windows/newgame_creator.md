# The empire creator (new game)

The screens the game shows when the player creates or edits an empire design before a new game
(Select Empire's *Create New* + *Select*, or *Edit*), drawn by the renderer from the game's GUI
files and run on the game's rules, checked against the real game (4.5.2 Linux, headless view mode
at the main menu: the same clicks and keys on both).

**[V]** marks what was read in the 4.5.2 Linux build (addresses are its) or seen in the game's
frames and files; **[I]** what is inferred.

## 1. Where it is

| file | what |
|---|---|
| `sim/render/lua/render/newgame_creator.lua` | the screen: ng-flow's entry point (`build`, `act`), the menu, Save / Done / Back, the popups |
| `sim/render/lua/render/creator_editors.lua` | the twelve editors' layouts and their clicks and keys |
| `sim/render/lua/render/creator_rules.lua` | the rules and data: lists, points, picks, requirements, the errors, the design's text |
| `sim/render/lua/render/empire_preview.lua` | the design's preview (`new_game_setup.gui` `species_preview`), shared with the empire selection |
| `sim/render/src/creator.rs` | tests (the rules, every editor, a design made as in the game) |
| `sim/render/src/app.rs` | typed keys to the focused text field (`App::input`) |
| `sim/render/src/flag.rs`, `scene.rs`, `gui.rs` | `@flag:` textures: a flag composed from its parts (designs no country has yet) |
| `sim/render/src/controls.rs` | `menu click left select`: the main menu takes clicks over the protocol |
| `headless/headless.c` | at the main menu and its screens: input, tick, wait, timestep, frame (ng-flow's `menu_command`, which took over this branch's first version) |

Entry point (agreed with ng-flow): `render.frontend_newgame` shows `Screen::Creator` and calls
`creator.build(game_dir, db, screen, texture_size, loc, RENDER_NEWGAME, RENDER_NEWGAME.empire)`;
the creator's buttons carry `creator:VERB[:ARG]` actions, which come back to
`creator.act(RENDER_NEWGAME, action)`: `nil` (stay), `"done"` (the design handed to
`render.newgame_setup.set_design`) or `"cancel"`. The creator keeps its state in
`RENDER_NEWGAME.creator` (`design`, `editor`, `focus`, `view`, `popup`). The base design is the
selection's: none gives the game's new design, a prescripted block is converted
(`rules.from_block`), a creator design is copied.

## 2. The screen [V]

`CCustomizeSpeciesView` (`interface/customize_species.gui`): the menu on the left
(`customize_species_view/menu`: its sections stacked in `editors_list`, each a
`customize_species_view_menu_entry_*` window sized by `customize_species_view_menu_section_size_N_buttons`
with its buttons at `..._button_pos_K`), the checkbox *Hide Unowned Content* at
`locked_content_checkbox_position` (the file puts it off screen, the code moves it), Save, Done,
Back. The editors are `NEmpireDesignEditor::EditorType` values in the static
`s_MenuButtonSections` (built at `0x18baee0`): each button's type, label and window:

| section | editor (type) | label | window (`customize_species_editors.gui`) |
|---|---|---|---|
| Background | Species & Portrait (0) | PORTRAIT | `species_portrait_editor` |
| | Government & Ethics (2) | ETHICS_AND_GOVERNMENT | `empire_ethics_and_government_editor` |
| | Origin (1) | EMPIRE_ORIGIN | `empire_origin_editor` |
| | Traits (5) | TRAITS | `species_traits_editor` |
| | Name Lists (4) | CUSTOMIZE_NAME_LISTS | `empire_name_list_editor` |
| | Empire & Species Names (3) | SPECIES_EMPIRE_NAME | `species_name_editor` |
| | Homeworld (10) | GOVERNMENT_VIEW_CAPITAL_LABEL | `planet_class_editor` |
| Secondary species | portrait, traits, name lists, name (6-9) | | only with an origin that has one (not done) |
| Empire | Advisor (12) | EMPIRE_ADVISOR | hidden (the game's frame shows no advisor button [I]) |
| | Flag (13) | EMPIRE_FLAG | `empire_flag_editor` |
| | City & Room (11) | CITY_GRAPHICS | `planet_city_gfx_culture_editor` |
| | Shipsets (14) | SHIPSETS_LABEL | `ship_gfx_culture_browser_editor` (`customize_species_shipsets.gui`) |
| Ruler | Ruler Appearance (15) | RULER_EDITOR_APPEARANCE | `species_ruler_editor` |
| | Ruler Traits (16) | RULER_EDITOR_TRAITS | `ruler_traits_editor` |

The buttons show the static labels, not the .gui's buttonText (the game's frame: "Ruler
Appearance", "Shipsets") [V]; an editor with errors has its label red [V: the frames; the colour
code I]; the open one its button's lit frame. Each editor is a 1040 x 405 window centred at
(-405, -50) over the preview's lower part, with Back / Next stepping through the menu's order.
The preview above it is `species_preview` (the empire's name, the flag, the room, the home
world's name and class); the ship set editor covers the whole preview (its own window, 1041 x 735).

Save and Done are greyed while the design has errors [V: the frames]. Done
(`CCustomizeSpeciesView::OnDone` `0x2ca71c0`) checks the design
(`IsCurrentDesignValidToSave`), then `CheckAndConfirmUnspentPoints` `0x2ca88c0`: ethic points or
civic picks left ask *Unspent Points* (UNSPENT_POINTS_NAME / _DESC), else ruler trait points left
ask *Unspent Ruler Trait Points*; one question only (the game's frame goes on after Yes with the
ruler's point unspent too) [V]. `popup.gui` `yes_no_popup_window`. After Yes the game goes on to
*Game Details* (the galaxy settings), not back to the selection [V] (ng-flow routes `"done"`).
Save keeps the design (the game writes `user_empire_designs_v3.4.txt`; here the creator's
`st.saved`) [I].

## 3. The rules (`creator_rules.lua`)

Read once from the game's files (`common/ethics`, `governments/authorities`, `governments/civics`
(origins: `is_origin`), `governments` (types), `governments/councilors`, `species_archetypes`,
`species_classes`, `portrait_sets`, `portrait_categories`, `traits`, `leader_classes`,
`name_lists`, `graphical_culture`, `planet_classes`, `solar_system_initializers`,
`scripted_triggers`, `defines`, `gfx/portraits/portraits`, `gfx/portraits/asset_selectors`,
`flags/`). Owned DLCs: the setup's (`RENDER_NEWGAME.dlcs`: the headless reference's 14), else every
installed one; `host_has_dlc` and the scripted triggers over it (`has_overlord_dlc` ...) answer
from them.

- **Requirement lists** (`potential` / `possible` of authorities, civics, origins, species classes;
  `governments/99_README_GOVERNMENT.txt`): `ethics`, `authority`, `civics`, `origin`,
  `country_type`, `species_class`, `species_archetype`, `graphical_culture`, `traits` with `value`,
  `OR`, `NOT`, `NOR`, nested `AND` / `OR` / `NOT`; on the configuration
  `SEthicGovernmentConfiguration::CreateWithDesignAndDefaultCountryType` makes [V].
- **Ethics** (`CEmpireEthicsGovEditor::OnClickEthic` `0x3445000`, `CCountryEthos::CanExchangeEthic`
  `0x252f910`, `AddEthic` `0x252f5c0` [V]): a chosen ethic is removed; another can be added when its
  cost fits the points (ETHOS_MAX_POINTS 3) less the ethics of other categories, and replaces its
  own category's (a fanatic its regular, egalitarian authoritarian); kept in the ethics' database
  order (the game's Save writes ethic_fanatic_egalitarian before ethic_xenophile chosen the other
  way) [V]. Ethics that cannot be added are greyed [I]; the chosen one's category ring
  (`GFX_ethic_selected`) on it.
- **Authorities**: those whose `potential` holds, greyed when `possible` fails; the government type
  is the first type of `common/governments` whose `possible` holds [I: weights not read].
- **Civics**: GOVERNMENT_CIVIC_POINTS_BASE 2 picks, each civic's `cost` (1); the list shows the
  civics whose `potential` and `possible` hold, sorted by name [V: the game's frame lists the same
  civics as here, Anglers ... Efficient Bureaucracy, none needing an ethic not chosen].
- **Origins**: those whose `potential` holds; the playable ones (their DLC owned) first, then the
  others, each in file order [V: the frame: Prosperous Unification, Progenitor Hive, Subterranean,
  Slingshot to the Stars, Teachers of the Shroud, Imperial Fiefdom]; not possible ones grey; the
  chosen one's description and its `description` effects (concept links shown as their text).
- **Traits** (`CSpeciesTraitsEditor::ShouldShowTrait` `0x34423f0`, `CanAddTrait` `0x3444ea0`,
  `CTraitSet::CanAddTrait` `0x1fbd5a0` [V]): shown when `initial`, valid for the species (portrait
  override, `allowed_archetypes`, `species_class`), the origin and civics, the home world's class;
  can be added when valid for the ethics, a pick is left (traits whose cost is not 0 count:
  species_max_traits 5, points 2 for BIOLOGICAL), no opposite is chosen. Points are not checked when
  adding: overspending is the design's error (TOO_MANY_TRAIT_POINTS_USED) [V]. The species class's
  and origin's / civics' / authority's forced traits are added and cannot be removed. Sorted:
  positive costs first by cost then name, then negative ones [V: the frame's order].
- **Portraits**: a category's sets' portraits, the playable ones first, the locked ones (a
  conditional set's `playable` failing: purple in the game, not selectable) after [V: the game's
  Save of a new design has `human`, the humans set's first, not the cybernetic set's before it].
- **Ruler**: classes from the authority's ruler council position (`leader_class`), starting ruler
  traits (`starting_ruler_trait`) of that class, `max_trait_points` 1. Titles from the government
  type (`ruler_title` / `_female`, heir titles only with `has_heir`) [V]; with no authority yet the
  game shows President [V] (gov_representative_democracy's [I]). The portrait's spinners: the
  portrait group's game_setup portraits for the ruler's gender (Phenotype), the portrait's
  `character_textures` (Color Variant), its attachment and clothes selectors' textures (Hairstyle:
  `custom_attachment_label`; Clothing) [I: the counts of distinct textures].

### The errors (`IsEmpireDesignValid` per editor, `0x2508e30` [V])

A jump table on the editor type (`0x468c544`); each check appends a localised key. Here
`rules.errors(R, design, editor)`:

| editor | checks (keys) |
|---|---|
| Ruler Traits | trait points over the class's (GAMESETUP_LEADER_TOO_MANY_TRAIT_POINTS_USED), class not of the authority's ruler position (GAMESETUP_LEADER_WRONG_CLASS_FOR_AUTHORITY), a trait of another class (…WRONG_CLASS_FOR_TRAIT) |
| Ruler | empty name (GAMESETUP_LEADER_NAME_MISSING), no gender for a gendered species (…GENDER_MISSING) |
| Names | species name, plural or adjective empty (EMPIRE_DESIGN_SPECIES_NAME_MISSING_FIELD), empire name, adjective (EMPIRE_DESIGN_MISSING_EMPIRE_NAME / _ADJECTIVE) |
| Name list | no such list (EMPIRE_DESIGN_MISSING_NAME_LIST) |
| Homeworld | class missing / not colonizable (EMPIRE_DESIGN_MISSING_PLANET_CLASS / INVALID_PLANET_CLASS), names (…MISSING_HOME_WORLD_NAME / _HOME_SYSTEM_NAME), the initializer (…INVALID_INITIALIZER) |
| Origin | not an origin or not possible (GAMESETUP_COUNTRY_INVALID_ORIGIN), not playable (GAMESETUP_CONTENT_NOT_PLAYABLE) |
| Ethics & government | over the points (NOT_ENOUGH_ETHIC_POINTS), under MIN_ETHIC_POINTS 3 (CUSTOMIZATION_TOO_FEW_ETHIC_POINTS), ethic not playable, authority missing or not possible (GAMESETUP_COUNTRY_INVALID_AUTHORITY), civics over the points (…CIVICS_TOO_EXPENSIVE), a civic not possible (…CIVIC_INVALID), the species class's `possible` (GAMESETUP_SPECIES_CLASS_GOVERNMENT_NOT_ALLOWED) |
| Traits | duplicates, a required trait missing, a trait not valid (TRAIT_INVALID_INITIAL), opposites, points (TOO_MANY_TRAIT_POINTS_USED), picks (TOO_MANY_TRAITS) |
| Portrait | none (EMPIRE_DESIGN_NO_PORTRAIT) |
| City, Shipsets | the culture missing or not selectable (EMPIRE_DESIGN_INVALID_GFX_CULTURE / UNAVAILABLE_GFX_CULTURE) |

A new design has exactly the game's red entries: Government & Ethics (too few ethic points, no
authority), Empire & Species Names, Homeworld, Ruler Appearance [V: the frames and their tooltips].
Not read in detail [I]: the species class vs government of a secondary species, the government
type's own check, the trait checks' order.

### The design and its text

`rules.default_design`: the game's new design (`CEmpireDesign("default")` copied by
`SetDefaultValues` `0x2505ba0`): Humanoid `human`, Prosperous Unification, Organic, Continental,
HUM1, Mammalian ships and city, the ruler `human_female_04` (Phenotype 4 / 5) with clothes 4
(Clothing 5 / 7), `default_room` [V: the game's Save]. The flag: the game rolls one
(`CEmpireDesign::RandomizeFlag` in `CGameSetupView::EditEmpireDesign`, its random stream); the
default here is one it rolled [I].

`rules.to_text(design)` writes the design as the game writes a user's design
(`user_empire_designs_v3.4.txt`) [V]: names as `{ key = ... literal = yes }` blocks (a localisation
key without `literal`), the empire adjective through `%ADJ%`, `government`, `is_nomadic`,
`ship_size`, the flag's six colours (flag 1, 2, 3, 4, map border, map fill), the ruler's name in
`full_names`, `room`, `spawn_enabled`, ethics, origin. **Checked**: the same inputs given to the
game's creator and this one (names, ethics, authority, home world, ruler) give identical text (the
test `a_design_made_as_in_the_game_is_the_games`). `rules.from_block` reads both this form and the
prescripted one; `to_block` gives the parse tree. ng-start takes the text
(`NewGameSettings.empire`).

## 4. The editors (`creator_editors.lua`), against the game's frames

All checked side by side at 1600 x 900 (`tmp_sym/render3d/newgame_creator/cmp_*.png`, the game
left; `cmpall.sh` on 10.5.0.24):

- **Species & Portrait** [V]: categories (`species_portrait_category_entry`), the grid of
  `species_portrait_picker_entry` (9 a row, cut to `portraits_container`), each with its species'
  portrait (docs/windows/portraits.md).
- **Government & Ethics** [V]: points left, the ethics' circle, the authorities' grid (two rows of
  four), the authority's description (NO_GOVERNMENT_SELECTED), the civics list and picks left.
- **Origin** [V]: the origins' pictures in a 3-wide grid cut to its window, the chosen one's
  description and effects.
- **Traits** [V]: points and picks (labels without their value: POINTS_LEFT's text), the available
  traits with their costs, the chosen ones.
- **Name Lists** [V]: ship prefix, the selectable lists by name (spacing -3: 29 apart), scrolled so
  the chosen one shows; examples: the list's first names [I: the game draws random ones].
- **Empire & Species Names** [V]: the edit boxes (the player's text, a caret when focused),
  gender buttons, randomize buttons (the list's first names [I]).
- **Homeworld** [V]: names, starting system drop-down (Random and the `custom_empire`
  initializers), the classes' places, the selection ring's window moved to the chosen one, the
  details (class, climate `wet` "(Wet Climate)", description, preference trait). The planets are 3D
  in the game: not drawn.
- **Flag** [V]: categories with a FLAG_CATEGORY_ name, emblems, the colour slots (1, 2 and the map's
  5, 6), the palette (`flags/colors.txt`), the backgrounds in greys.
- **City & Room** [V]: the city sets over the home world's landscape
  (`species_preview_backgrounds`), named "$CULTURE$ City" by the species class using the culture;
  the room tab: the room selector's game_setup rooms (asset_selectors/room_textures.txt) [V: the
  frame shows the same rooms in the same order; the game draws them over black, here over the panel].
- **Shipsets** [V layout]: Biological (cultures with `bio_ship`) and Mechanical groups, the chosen
  set's description, the ship class spinner, the ship colours. The ship and the thumbnails are 3D:
  not drawn.
- **Ruler Appearance** [V]: name, sex (male, female for a gendered species), titles, the portrait
  spinners, biography.
- **Ruler Traits** [V]: the class spinner, the starting traits of the class with their icons
  (`GFX_leader_trait_*`), points left.

Text input: with a field focused (a click on it), the renderer's keys go to it (`App::input`:
letters, digits, space, `-`, `'`, `.`, `,`; Shift for capitals; Backspace, Return, Escape, Tab).

## 5. Not done

- The Homeworld editor's planets and the Shipsets editor's ship and thumbnails (3D in the game;
  the preview's ruler, species portraits, home world and ship are drawn: docs/windows/portraits.md).
- The secondary species' editors, the advisor editor, nomadic empires (the nomad toggle, arkships).
- The right column of DLC icons and *Recommended DLC* (the selection screen's, ng-flow's).
- Tooltips (the errors show in the menu's tooltips in the game), the list scrollbars and wheel.
- Random names and flags (the game's random stream).
- Save writes no file; the game's ConfirmedBack question on Back.

## 6. Checking against the game

On 10.5.0.24 (`/root/ngc`): `game.sh 7941` starts the game at the main menu (private
HEADLESS_ROOT `/root/ngc/hroot`), `gnav.sh` opens its creator, `ren.sh 7942` / `rnav.sh` the
renderer's; `c.sh PORT CMD...` sends commands (`press X Y`: button down, two frames, up),
`cmp.sh NAME CMD...` runs them on both and writes the pair; `flow.sh PORT` makes the test design
(`flowsave.sh` saves it in the game: its `user_empire_designs_v3.4.txt` in the work dir).
