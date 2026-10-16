# The diplomacy windows

Contacts, a country's diplomacy, the galactic community, the federation and a war's overview, as
Stellaris 4.5.2 (Linux) draws them and as stellar-render lays them out from the game's own .gui
files. **[V]**: read in the game's code (function @ address in the Linux build) or files, or
measured in its frames; **[I]**: inferred. Long-form reading notes (every element, every
condition) were kept beside the repository in `code_working/tmp_diplo/re_*.md`; what matters for
the renderer is here.

## 1. In the renderer

- `src/diplomacy.rs`: which window is open (`State::open`: Contacts, a country, the community, a
  federation, a war), its tab, the selected empire and the sort. Actions: `view:contacts` (the left
  bar's button, a toggle as CInGameIdler::ToggleTopBarView), `diplo:close`, `diplo:select:ID`,
  `diplo:country:ID`, `diplo:tab:NAME`, `diplo:sort:METHOD[:desc]`, `diplo:community`,
  `diplo:federation:ID`, `diplo:war:ID`, `diplo:none` (a window's background takes the click).
  Escape closes the window first. `App::action` does an action as its click does.
- `lua/render/windows/diplomacy_data.lua`: what the windows read of the world (every country, the
  player's relation to each and theirs to the player, intel, opinion where the engine computes it,
  attitudes, federations, wars, the community), made where the world is (`render.galaxy`
  extract: the save's runtime, or the simulation's thread for its snapshots) and carried as a Lua
  chunk (`Galaxy::diplomacy`) to the front end's runtime. Each country it lists gets its flag
  among the galaxy's countries (`add_country`), so the renderer composes the flags (flag.rs).
- `lua/render/windows/diplomacy.lua` and `diplomacy_<window>.lua`: the layouts (render.gui), with
  what the game decides at run time (`hide`, `text`, `frames`, `sprites`, `actions`).
- The command protocol: `open_diplomacy contacts | country ID | community | federation ID |
  war ID | close` (and `select ID`, `tab NAME`, `sort NAME`), served by the renderer
  (engine.rs) and by the game (headless.c: `contacts [TAB]` CInGameIdler::ShowGalaxyView and
  CGalaxyView::Show(ETabsGalaxyView); `country ID [TAB]` ShowDiplomacyView(country, tab, 1, 1) as
  Contacts' Diplomacy button calls it; `community [TAB]` ShowGalacticCommunityView; `federation`
  CFederationView::Show; `close` CloseTopBarViews and CDiplomacyView::Hide). `open_view contacts`
  (win-empire's) opens Contacts too.

## 2. Contacts (interface/galaxy_view.gui, CGalaxyView)

- The window at its show_position (35, 40), 1272 x 620 **[V]**. Tabs: 0 Contacts, 1 Agreements,
  2 the Shroud; the first opening shows Contacts, a reopening keeps the last tab (Show does not
  reset it) **[V ctor; I keeps]**. The Agreements button is enabled only with an overlord or
  subjects, else disabled (not hidden); the Shroud's tab needs its DLC **[V Update @2e3e4a0]**.
  `header`: topbar_button_contacts_name, xenos_ui_agreements, NAME_The_Shroud **[V UpdateTab]**.
- **Who is listed** (ShouldShowEmpire @2e3f100, IsCountryVisibleTo @2444ed0) **[V]**: the player's
  own row always; another country when its type (common/country_types) has
  `show_in_contacts_list = yes` and the player has communications with it. Then the type filters
  (all checked at Setup): a type with a `filter_checkbox_<type>` (default, fallen_empire,
  primitive) colours its row's empire_type with its label's text_color_code (W, H, L); the others
  are "other" (M). In the 2212.07.01 save: the Mandasuran Ravagers (marauders, purple) and the
  player's Sacred Uthabulan Order; the DAAR Eradicators (contact, no communications) are not
  listed **[V the game's frame]**.
- **Order**: SortCountries, a stable sort over the countries by id; by name A..Z by default; a
  header (name, empire_relations, power, status, alliance_federation, planets, war_status)
  sorts by its method, the same header again flips the direction **[V]**.
- **Selection**: the clicked row, else the first row (UpdateEmpires @2e3e9fc) **[V]**; its
  `selected_overlay` shown.
- **A row** (CGalaxyEmpireItem::Update @2e5f4d0) **[V]**: flag; name; empire_type in the filter's
  colour (the player's "Player Empire" in yellow, the marauders' "Marauder Clans" in purple by the
  frame **[I: GetCountryTypeString not read; the government's name for AI countries]**);
  empire_relations their opinion of the player (GALAXY_VIEW_EMPIRE_ENTRY_THEIR_OPINION), DASH on
  the player's row; power only for others of a type with relations and no custom opinion;
  planets and the federation with the intel for them; the pacts' icons; the war icon (frame 1
  offensive, 2 defensive) in any war.
- **The profile** (CGalaxyViewEmpireProfile::Update @2e5b240) **[V]**: `empire_profile_minimalist`
  for types with `minimalist_contacts_list_profile`; the flag, the name, the government and its
  authority icon and the personality with government intel ("Played By: ..." in §M for humans;
  hidden for the player and types without relations); the diplomacy stats
  (NCountryDiplomacyStatsView): pops, diplo weight, sprawl, power and stance hidden for the
  player and types without relations; intel ("Intel:10") hidden on the player; opinion: theirs of
  us, the bar GFX_diplomacy_opinion_<level> filled 100 x (v - lo) / (hi - lo) within the level's
  interval (OPINION_* defines: -1500, -750, -300, 300, 750, 1500), the label the AI's attitude to us
  ("None" for the marauders by the frame) or PLAYER_EMPIRE_SP.
- **Intel** **[V files]**: common/intel_levels gives each range of intel (0-9, 10-19 ... 99-100) a
  level per category (government, diplomacy, economy, technology, military) and its icon's
  frame (GFX_intel_level_N); common/intel_categories lists each category's items by level. An item
  is known from the first intel whose level reaches its own (`authority` and `ethics`: 10;
  `intel_economy_colonies_low`: 30; `intel_empire_sprawl`: 70). The EIntelInfo bits the code tests
  are matched to items by name **[I]**: government 0x2 `authority`, ethics 0x20000, colonies 0x800
  `intel_economy_colonies_low`, sprawl 0x2000, federation 0x80000 `federation_name`; pops (0x400)
  has no item and takes the colonies' **[I]**. The save's intel: the player's `intel_manager =
  { intel = { { ID { intel = N } } } }` (each pair reads as `ID = { ... }`).
- **Icons the engine finds by name** **[V files; I the lookups]**: the authority's
  gfx/interface/icons/governments/authorities/<key>.dds, the ethics' gfx/interface/icons/ethics/
  <ethic>.dds (the fanatic ones have no GFX_ sprite), the civics' .../governments/civics/<civic>.dds;
  laid in their OverlappingElementsBox at their size (overlapping when they do not fit), the box's
  format aligning them.
- The pacts' icons in a row (CDiplomaticPactsTowardPlayerView: 33 status types in a fixed order,
  their sprites **[V]**) from the relations' flags **[I: HasDiplomacyItemTowardCountry not read]**;
  none for a country type without relations (the marauders' closed borders show none in the frame).
- Not drawn yet: the species portrait (CPortraitObject), the detailed diplomacy list, the
  agreements tab's lists, the row's relative power (shown as Unavailable), the diplomatic weight.

## 3. A country's diplomacy (interface/diplomacy_view.gui, CDiplomacyView)

- 1280 x 635, centred **[V]**; 990 wide after an action is picked (SetWideMode). Opened from
  Contacts' Diplomacy button with ShowDiplomacyView(country, 0, 1, 1) **[V @2e3fe22]**; never for
  the player's own country and only with communications (CanActWith) **[V]**.
- The marauders: ShowDiplomacyView on them shows an event window ("Incoming Transmission", with
  their options) instead **[V the game's frame; the route not read]**.
- Default tab Diplomacy, remembered between openings **[V]**. Opinion: theirs of us, its level's
  bars (frame level + 1), the trend against the relation's last month; the stats item's label is
  the AI's attitude **[V]**. The actions list: common/diplomatic_actions in file order, the
  possible ones first **[V; I file order]**: not built here (its `potential` and `possible`
  triggers need the script layer).

## 4. The galactic community and the federation

- **Galactic community** (CGalacticCommunityView) **[V]**: the top bar's button only once the
  community is formed (none of the saves: their `galactic_community` block has no members); the
  view opened directly shows, for a non-member: Proposal Queue with "No Resolutions have been
  Proposed", "Would you like to join us?" (the event key ancrel.2019.c) over MUST_BE_MEMBER
  (highlighted_type_background frame 4), "Support Options Disabled ...", the greeting of the player
  itself (its flag, name, government, "Played By: unknown") with "Welcome to the Galactic
  Community!", the members box in its large layout (no council positions), Select a Leader, Join;
  the Senate Floor tab disabled. Checked against the game's frame (2212.07.01). The diplomatic
  weight (country +0x2f40, a modifier total not in the save) is not shown **[I]**.
- **Federation** (CFederationView) **[V]**: only the observed country's federation; without one
  (the player in every save) the button is hidden and the view hides itself. Tabs Levels (first),
  Members, Fleets, Laws.

## 5. War overview (interface/waroverview.gui, CWarOverview)

- The player's side on the left (ATTACKERS or DEFENDERS), exhaustion as a whole percent coloured
  by side (green/red under 30 %, yellow to 70 %, red/green above), the top bar split at
  d = theirs - ours **[V]**. Opened from the at-war badges, the diplomacy view's action, war
  messages and alerts, not from Contacts **[V]**. No save has a war: laid out by the code only.

## 6. Names, layout rules (shared files)

- render.names: `%ADJECTIVE%` takes the localisation's adjective form, `adj_NN<ending>` (the
  longest of the word's last three letters that has a key; `*` the word without that ending):
  SPEC_Mandasura "Mandasuran Ravagers" as the game's Contacts shows it **[V the frame; the keys
  in name_system_l_english.yml]**.
- render.gui: a `checkboxType` is drawn as a button whose frame the caller gives (the filters'
  checked frame 2, by the frame); a button's `text` is its text when it has no `buttonText` (the
  community's assign_button reads LEADER_ASSIGNMENT, "Select a Leader", in the game's frame), and
  a text the game sets at run time is drawn on any button.
- Texts the game wraps (instantTextBoxType without `fixedSize = yes` grows to more lines; with
  it, it is cut) are cut here until the wrapping that win-economy and win-empire add lands
  ("No Resolutions have been Proposed", MUST_BE_MEMBER, "Support Options Disabled ...").

## 7. Checked against the game

Same commands on both (autosave_2212.07.01, 1600 x 900, the game by `headless/view.sh` with
`open_diplomacy`); side by side in `code_working/tmp_diplo/parity/` (the game left):

- `parity_contacts.png` (`open_diplomacy contacts`): the same two rows in the same order (the
  Mandasuran Ravagers, "Marauder Clans" in purple, opinion 0, selected; the Sacred Uthabulan Order,
  "Player Empire", "-", 1 planet), the checked filters, the sort headers, the profile (name,
  authority icon, government, both ethics icons, Intel:10 with its bar, "Unavailable" espionage,
  the neutral opinion bar labelled "None"), the Diplomacy and Espionage buttons, the tabs. Not
  drawn: the marauder portrait.
- `parity_community.png` (`open_diplomacy community`): the portrait background, the player's
  greeting (flag, name, Theocratic Dictatorship, "Played By: unknown", "Welcome to the Galactic
  Community!"), "Would you like to join us?" on its red banner, the members box, Select a Leader,
  Join, the tabs. Different: the cut texts above, the ruler's portrait, the diplomatic weight (195
  in the game).
- `g_country16.png`: the game's "Incoming Transmission" for the marauders; the renderer opens no
  diplomacy view for them. `g2_agreements.png`: `open_diplomacy contacts 1` shows the Contacts tab
  in the game (the agreements tab is disabled without an overlord or subjects): the renderer
  likewise.
- The diplomacy view of a regular empire, the federation and the war overview have no frame to
  compare: in every save the player has communications only with the marauders, belongs to no
  federation and is at no war. They are laid out by the code read (sections 3 to 5).
