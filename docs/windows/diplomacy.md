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
  `diplo:federation:ID`, `diplo:war:ID`, `diplo:peace:OPTION`, `diplo:peace_send`,
  `diplo:member:VERB` (a leave first opens its yes/no popup), `diplo:confirm_yes`, `diplo:confirm_no`,
  `diplo:inspect:KIND:ID` (an object to the log, for the tests), `diplo:none` (a window's background
  takes the click).
  Escape closes a popup first, then a picked action, then the window. `App::action` does an action
  as its click does.
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
  the button is hidden and the view hides itself. Tabs Levels (first), Members, Fleets, Laws.
  UpdateGeneralInfo: the name, the type (FEDERATION_VIEW_TYPE: the type's name, e.g.
  default_federation "Galactic Union") and its icon, its description, "Formed:", the first perk's
  modifier under its header (FEDERATION_PERK_FED_MOD and the modifier's `description`), a law
  (FEDERATION_VIEW_LAW_DESC; the centralization **[I: which category]**), the members by economy
  (small_member_item: flag, name, economy rounded). The Levels tab: the level (FEDERATION_LEVEL), XP
  against the next level's (FEDERATION_EXPERIENCE; the type's `levels` and the file's
  @xp_to_level_N), the XP gain (cohesion x FEDERATION_COHESION_TO_XP 0.1: -3.50 at -35), the
  cohesion bars (progress bars: the positive one filled to cohesion / 100, the negative one to 1 -
  |cohesion| / 100), the envoys; a level_item per level of the type with its perks' icons
  (gfx/interface/icons/federation/federation_perks/<perk>.dds **[I]**, drawn at the texture's
  42 x 42, 21 right of and 3 under the grid's slot as the game's frame has them, greyed on a locked
  level). The Members tab (federation_member_entry): flag, name, "Player Empire" or the AI's
  personality, economy / fleet / technology ("$VALUE|0W$", C's %.0f: 252.5 shows 252), their
  opinion of us (+20 in the game's frame), the ethics' icons; the sort above (§8). Not computed:
  the monthly cohesion growth (a modifier total; -1.07 in the game), the members' diplomatic
  weight and envoys (196 and 210, 0 and 0 in the game), the president's portrait, the opposing
  ethics' marks.
- Texts filled with values (`ctx.fmt`): the values go in first, then the text's other `$KEY$`
  references are resolved. Resolving first turned a value named like a key into that key's text
  (FEDERATION_VIEW_TYPE's TYPE showed "Type", the law's NAME "Name", the XP's TOTAL "Total").
- The yes/no popups of a leave (popup.gui yes_no_popup_window, centred): the description wrapped
  (render.windows.events' wrap, with its text icons) and the window grown to it, its top kept:
  max(180, 146 + lines x 16) **[I: fitted to the game's two frames]**.

## 5. War overview (interface/waroverview.gui, CWarOverview)

- The player's side on the left (ATTACKERS or DEFENDERS), exhaustion as a whole percent coloured
  by side (green/red under 30 %, yellow to 70 %, red/green above), the top bar split at
  d = theirs - ours: progress bars (progressbarType, textureFile1 up to the state), the left one
  filled to 1 + d, the right one to d **[V]**. Opened from the at-war badges, the diplomacy view's
  action, war messages and alerts, not from Contacts **[V]**.
- **Exhaustion** (CWar::CalcCachedWarExhaustion @2142840; not saved) **[V]**: attrition is the
  war's attacker/defender_war_exhaustion; the battles add theirs by type (ships, armies,
  static_war_exhaustion) in order while the running total is under
  WAR_EXHAUSTION_FROM_UNITS_CUTOFF (1.0); the total is their sum. Occupation (CalcOccupationPercent)
  is not computed here: 0 **[I]**.
- **Participants** (NWarParticipantsList) **[V]**: the list's height is the positionType's (305 x
  155 with the Set War Goal button, else 305 x 194; the gui's own is 0); a 38-high entry per
  participant in the save's order: the flag, the name, the `frame` never shown, the `type` icon by
  the call type (none for the main participant; `alliance` GFX_diplomacy_status_federation, and so
  on: NWar::ApplyCallerTypeToButton @2153d60).
- **Peace offers** (COfferPeaceAction, `diplomacy_peace.lua`) **[V]**: the actor is the player, the
  recipient the other side's main participant. Achieve War Goals = demand (status 2), Settle Status
  Quo = 0, Surrender = 1. Surrender is always auto-accepted (shown "Auto" with the check, frame 2);
  it cannot be sent by an attacker before the defenders set their war goal
  (SEND_OFFER_NO_DEFENDER_DEMANDS: label and value greyed). The acceptance (GetOfferPeaceAcceptance
  @27f7710, NAI defines): status quo PEACE_STATUS_QUO_FACTOR (-75), +100 at the recipient's war
  exhaustion 1.0 or more; demands PEACE_DEMAND_SURRENDER_FACTOR (-100) and the war goal's
  `surrender_acceptance`; both + war exhaustion x 100 + occupation x 100 + the relative navy:
  min(50, (ratio - 1) x 50), ratio = (100 + the actor side's fleet power) / (100 + the recipient
  side's), clamped to 0.1..10. The fleet power is the save's `military_power` **[I]**. Shown green
  above 0, red otherwise, no sign; "Auto" at 1000. Not computed: the stalemate term, the demanded
  systems' terms, favors. The war goal icon on Achieve (ours) and Surrender (theirs): GFX_ and the
  type's icon, else its key **[I]**; none keeps the gui's. The goals' names above the options
  (war_goal_<type>).
- On the test save (war_gc_2212.sav) the renderer gives Achieve War Goals -243 and Settle Status
  Quo -118, as the game: -100 - 100 - 43 and -75 - 43, the navy term (271.9 / 1901.7 - 1) x 50.

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
- Test saves made by the game itself (headless.c's `console NAME ARGS` runs a console command,
  `save DIR` saves; on .24 in /root/diplo): contact_2212.sav (communications with 16777223),
  war_gc_2212.sav (the player attacks 16777223, allied with 49 and 50, Vassalize; the galactic
  community formed with 11 members), fed_2212.sav (the federation 1, Rebel Coalition, Galactic
  Union, the player leading it with 16777218). war_dgoal_2212.sav is war_gc's with a defender war
  goal (wg_humiliation) written in, so that Surrender can be sent. The game's frames: g8_war.png,
  g8_community.png, g9_federation.png.
- The war overview against g8_war.png: the same participants (the player; 16777223, then 49 and 50
  with the federation icon), the exhaustion 0 % in every row with the bars green, the top bar,
  Vassalize over Achieve War Goals -243 and Settle Status Quo -118 with the red X, Surrender
  greyed with "Auto" and the check. Sending: Achieve War Goals refused (-243); on
  war_dgoal_2212.sav Surrender accepted (1000), wg_humiliation's on_accept, on_war_won /
  on_war_lost (the game's "Defeated by ..." event shows) and on_war_ended run, the war gone.
- The federation view against the game's frames of fed_2212.sav (g9_federation.png, g10_fed.png,
  g10_members.png, g16_name1/2.png, g16_econ.png): the general info, the levels grid, the members'
  rows and their order by each click, the Leave popup (g11_click.png). Leave Federation's result
  against the game's save after Yes and a day (the `open_diplomacy inspect KIND ID` command prints
  an object as the save writes it): the same members, cohesion (-100), truce, relations and
  opinion modifier; federation 1 gone.
- The community against the game's frames of war_gc_2212.sav (g8_community.png, g13_popup.png,
  g15_before/after.png) and its saves after Leave and after Join (join_2212.sav: the game's own
  save after Leave with left_galactic_community taken out): the same members, influence, timed
  modifier, flag and opinion_fellow_galcom_member modifiers. This needed the script layer's
  has_opinion_modifier trigger (simscript/handlers/diplomacy.lua; engine/ethics/script.lua had it
  only while the ethics evaluate) and the commands' script effects applied at once
  (simscript.eval.sync after each on_action and effect run).
- In a real window (winshot under Xvfb, the save loaded from Load Game): the federation opened from
  its button, Members, Name, Leave, Yes (the view and the button gone); the community opened from
  its button, Leave, Yes (the non-member view, Join greyed); the war opened from its badge, the
  greyed Surrender not taking the click, Settle Status Quo selected, Send (refused at -118).

## 8. The buttons

What each element the game takes clicks on does, and how far the renderer does it. The world's
changes go through the simulation (render-buttons-1's views.rs: `render.windows.contacts`'s
`command(...)`, run between days, the simulation started if it is not running, a snapshot taken
after): `list` (a country's actions) and `propose` (an action) in `lua/render/windows/
diplomacy_actions.lua`; `peace` (a war's peace offer) in `diplomacy_peace.lua`;
`leave_federation`, `join_community`, `leave_community` in `diplomacy_membership.lua`. The command
protocol's `open_diplomacy action KEY`, `confirm`, `filter NAME`, `zoom ID`, `select ID`, `tab
NAME`, `sort NAME`, `peace OPTION` (force_demands, status_quo, surrender), `peace_send`, `member
VERB`, `confirm_yes`, `confirm_no` do the same as the clicks; `inspect KIND ID` (KIND `top` for a
top-level block) replies with the object as the save writes it.

| window | element | the game | here |
|---|---|---|---|
| Contacts | the left bar's contacts button | ToggleTopBarView: shown, or hidden when shown | wired |
| Contacts | close, Escape | CGalaxyView::Hide | wired |
| Contacts | a row (its background, its flag) | OnBackground: the row selected, its profile shown | wired |
| Contacts | the sort headers (name, opinion, power, status, federation, planets, war) | ChangeEmpireSortingMethod: its method, the same header again flips | wired (name, opinion, planets, war sort; power, status, federation sort by name [I]) |
| Contacts | the filter checkboxes (empire, fallen empire, pre-FTL, other, non-player) | the list filtered (ShouldShowEmpire) | wired (frame 2 checked, 1 unchecked) |
| Contacts | Diplomacy | OnEmpireDiplomacy: ShowDiplomacyView(country, 0, 1, 1); disabled without IsDiplomaticViewAvailableFor | wired (enabled with communications; the marauders' own event is not shown) |
| Contacts | Espionage | the window on its espionage tab; disabled without IsEspionageAvailableFor | UI only (disabled: the spy networks are not read here [I]) |
| Contacts | zoom to capital | OnEmpireZoomToCapital: the camera to the capital | wired (the capital's system entered) |
| Contacts | the Agreements tab | the agreements' list (CAgreementsListViewController); disabled without an overlord or subjects | disabled as the game; its lists not done |
| Contacts and Diplomacy | the lists' wheel (the empires, the actions) | the list scrolled | wired: a row a notch over the list (no save lists more rows than fit, so it has not had rows to move) |
| Diplomacy | close, Escape | CloseClick; Escape cancels a picked action first | wired |
| Diplomacy | the capital (to_to_home_world) | the camera to the capital | wired |
| Diplomacy | the tabs | OnTabButton: Diplomacy, Espionage (enabled by IsEspionageAvailableFor) | Diplomacy wired; Espionage disabled (its tab's lists not done) |
| Diplomacy | an action's entry | SelectAction: its view (the window 990 wide, the action's title, description, icon), Confirm and Cancel; disabled when it cannot be proposed | wired; the trade deal, declare war, proxy war, offer peace, agreements and claims open their own windows in the game [not done here] |
| Diplomacy | Cancel | CancelAction: the list again | wired |
| Diplomacy | Confirm | the action proposed (CDiploActionProposeCommand); an AI recipient accepts when its acceptance is above 0 | wired: the acceptance computed (section 9), the reply phrase in the bubble; accepted: the pacts (both sides; a defensive pact clears a non-aggression pact and a guarantee), the embassy (both sides), a guarantee, borders, rivalries, the embassy recalled, the pacts broken, an insult (opinion_insult on the recipient's opinion of us, through the engine's add_opinion_modifier: +27 to -173 on the test save); then the type's on_accept effect and the pacts' on_sign_* on_actions through the script layer; federation joins and associations, subjugation, trade deals [not done here] |
| Diplomacy | the AI's acceptance icons | frame 2 accepts, 3 with the favors held, 1 refuses; for diplo_view_acceptance_icon actions and an AI recipient | wired where the acceptance is computed (section 9) |
| Main view | the federation button (alliance_button_window), the community button (galactic_community_button_window), the war badges (waroverview_list) | OpenAllianceView, the community view, ShowForWar; each shown when there is one (a federation of the player's, a formed community, a war of the player's) | wired: drawn where the game's frames have them, the buttons toggle their view, a badge opens its war (its flags and both sides' exhaustion); the community button's unread count and vote balance hidden without a resolution [I] |
| Community | close, Escape; the tabs | Hide; Community, Senate Floor (disabled for a non-member), Resolutions | wired |
| Community | Join / Leave | CJoinCommunityCommand (100 influence; not within 7200 days of leaving: left_galactic_community) / CLeaveCommunityCommand (sprawl x 0.5 influence, 100..500; not the custodian), after a yes/no popup | wired (`diplomacy_membership.lua`): the cost paid, `members` (and the council, the emissaries) changed, left_galactic_community for 7200 days, on_add_community_member / on_remove_community_member run (galcom.60 / galcom.61 add or remove opinion_fellow_galcom_member both ways, galcom_form_nay set); Leave asks with the game's yes/no popup (CONFIRM_LEAVE). Checked against the game's saves after Leave and after Join: the same members, influence (-100), timed modifier, flag and opinion modifiers. Not done: the new member's communications |
| Community | Select a Leader | the delegate's leader selection (CAssignOfficialWindow) | not done |
| Community | resolutions, votes, the senate floor | CProposeResolutionCommand, the decisions (support, oppose, abstain, veto, ...) | not done: the test save's community has no resolution proposed and 718 days of recess |
| Federation | close, the tabs (Levels, Members, Fleets, Laws) | Hide, SwitchToTab | wired |
| Federation | the members' sort buttons | OnSetSortType: by the button, the same one again reverses | wired: by default economy, descending [I]; another button sorts by it descending, the same again ascending (the game's frames after Name once and twice); name, economy, fleet, technology, opinion (diplomacy, envoys, ethics by name [I]) |
| Federation | Leave Federation | a yes/no popup, CLeaveFederationAction (auto-accepted; requires_actor_peace) | wired (`diplomacy_membership.lua`): out of `members` and its envoys, its `federation` gone, cohesion -100, with each remaining member the relations' `alliance` gone, a truce (alliance, an empty name) and opinion_broke_federation (-200) towards it; with fewer than 2 members left the federation ends (the game at the next day's tick, here at once [I]); first the game's yes/no popup (POPUP_LEAVE_FEDERATION_TITLE / _DESC). Checked against the game's save after Leave and a day. Not done: a new leader by the succession law, Ask to Leave |
| Federation | rename, type, laws' votes, Select a Leader | CRenameAllianceCommand, CVoteForFederationTypeAction / LawAction (a vote), the leader selection | not done |
| War | close | Hide | wired |
| War | the peace options | OnClickOfferPeaceOption: one selected, the same again unselects; disabled when invalid | wired (the option's window takes the click; an invalid one none) |
| War | Send Offer | the offer proposed, the window closed; an AI accepts above 0 | wired (`diplomacy_peace.lua`): accepted, the winner's war goal `on_accept` (status quo: both goals' `on_status_quo`, on_status_quo), on_war_won / on_war_lost, a truce between every attacker and defender (the war's name, truce_type war), the war out of the relations' `wars`, on_war_ended, the war removed; a refused status quo gives opinion_status_quo_not_accepted [I: its direction]. Not done: claims ceded, the opinion between the main participants, the effects the script layer does not have (set_subject_of) |
| War | set war goal, the battle log's headers | CWarGoalsView, SortBattles (stable, ascending first) | not done (no battles in the test save) |

The diplomatic actions listed (§3): common/diplomatic_actions in file order, `is_listed = no`
dropped, their `potential` triggers evaluated by the simulation's script layer (this = the
player, from = the recipient), the possible ones (`possible` and `proposable` holding) first. The
engine's own checks (CDiplomaticAction subclasses' IsPotential) are approximated from the
relation's state: a pact formed or not, rivalry, embassy, closed borders, a federation's members
(no defensive pact, non-aggression pact or guarantee with one), subjects, spy networks [I]. On the
test save (autosave_2212.07.01 with communications added to the empire 16777223) the renderer
lists the game's seventeen actions plus Pledge Secret Fealty; the game puts Close Borders among the
possible and Make Claims among the impossible ones, the renderer the other way round: the script
layer's `possible` checks that read intel (`has_intel`) are not those of the game yet.

## 9. The AI's acceptance (`diplomacy_actions.lua` A.acceptance, run in the simulation)

Read in GetAIAcceptance @27f7230 and its per-type functions (the long notes:
`code_working/tmp_diplo/re_acceptance.md`) **[V]** unless marked:

- The total: an auto-accepted action without `diplo_view_acceptance_icon` 1000; else the action
  type's own terms (below; an action without a function of its own: none), + favors x
  DIPLO_ACTION_FAVOR_AI_ACCEPTANCE_VALUE (5), + the type's scripted `ai_acceptance` weight (root =
  recipient, from = actor; the actor's `diplo_action_acceptance_add` modifier is not added here
  **[I]**). Accepted above 0 (0 refuses). The actions needing a federation's vote end as 1 or 0;
  with the recipient its federation's leader no other member votes, so its own total decides.
- Each term truncated to an integer, in the game's order. ATTITUDE: the recipient AI's attitude
  towards the actor (common/attitudes behaviour: alliance, coexist, attack or weaken: -1000,
  other); OPINION: the recipient's opinion of the actor (engine.ai.opinion) x the type's factor;
  relative power min((max(p, 0) - 1) x factor, max), p = the actor's power over the recipient's
  (RELATIVE_POWER_FLEET/ECONOMY/TECH_MULT on the saves' military, economy and tech power; intel
  not applied **[I]**); shared allies (third countries in a defensive pact with both), shared
  rivals **[I: rivals of both, either way]**; the recipient's pacts of the kind x NUM_PACTS (unless
  the pact exists); the recipient's personality's `<type>_acceptance` (the embassy reads
  defensive_pact_acceptance, as the game); DISTANCE: 0 when bordering, else min(border distance,
  1000) x mult, rounded (the relation's `borders` and `border_range` **[I]**).
- Per type: the embassy, the defensive and non-aggression pacts, the guarantee (its base plus the
  whole non-aggression formula plus THREATENED), the commercial pact (the trade given and received
  not computed: 0 **[I]**), the research agreement (the techs one has that the other lacks, each way,
  x -0.5, within -100..100), the migration treaty (the actor's largest threat x -0.5), asking for
  association (the non-aggression block) and asking to join a federation (the federation terms; the
  voted-down modifier, the war philosophy's difference and the crisis term not read **[I]**). Not
  computed: trade deals, subjugation, secret fealty, invitations to a federation, the pre-FTL
  actions (no icon, no answer). The shared threat (GetSharedThreatFactor) is 0 here **[I]**; the
  recently-human term is not applied.
- The reply: the first phrase of common/diplo_phrases' `<action> = { accept|refuse }` whose trigger
  holds (root = recipient, from = actor) **[I: the game picks a weighted random one with the
  action's seed]**, shown in the bubble.
- Checked on the test save: the game's frame shows the refusal icon on the embassy, the commercial
  pact, the research agreement, the migration treaty, the association and joining the federation;
  the renderer computes all six as refused (the embassy -27: attitude -25, opinion 13, personality
  10, distance -25), the same icons.
