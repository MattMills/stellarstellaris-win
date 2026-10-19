# Events, the Situation Log, Discoveries, first contacts (4.5.2)

The renderer's event windows, the Situation Log and the Discoveries view, laid out from the game's
own .gui files and checked against the real game's frames (`headless/view.sh`, 2210.01.01,
1600x900). **[V]**: read in the game's code or files, or measured on its frames; **[I]**: inferred.

Code: `sim/render/src/events.rs` (the windows' state, clicks, the `event` command),
`sim/render/lua/render/windows/events_data.lua` (what they show, read from the world where the
galaxy is read: Galaxy::events), `events.lua` (the event window, the first contact view, the
popups), `situation.lua` and `discoveries.lua` (left bar views: views.rs' `extract` / `build(ctx,
data, state)`, ETopBarView tokens "situation" and "discoveries").

## Commands (both the game's headless and the renderer)

| command | |
|---|---|
| `event` | the open player events: `ok event ID:NAME ...` (the game: CGameState +0x180, COpenPlayerEvent +0x180 its id) |
| `event ID` | that event's window opened (the game: CInGameIdler::AddEventWindow, as CMessageSystem::Update does) |
| `event fc ID`, `event fc` | (renderer) the first contact view of first contact ID; closed |
| `open_view situation [tab anomalies]`, `open_view discoveries` | the left bar's views (win-research's command; the game's tab by a `click`) |

Why `event` exists **[V]**: the headless `step` runs ticks without the message system's update, so
an event fired for the player while stepping is never opened (180 days from 2210.01.01 show none),
and the events open in a loaded save are not shown either (the game's frame after a load has
none; the alert or the Situation Log leads to them). The save's own open event, `first_contact.1`
(53), is the reference.

## The event window (interface/eventwindow.gui `EventWindow`, CEventWindow::Setup 0x2d2ed70) [V]

- Centred (orientation and origo center), 490 wide, as high as its last option's bottom + 10
  (without options the description frame's bottom + 10); laid out at its .gui size first, then
  resized: at 1600x900 with one option and five lines it is at (555, 262), 490 x 378, as the frame.
- The description frame: as high as its text + 32 (the text's height, then SetSize); its place is
  read with GetPosition (after the anchors) and set back with SetPosition (a position): with
  orientation and origo center_up, x -14 becomes 0 and then 14 from the window's left. y: 220 plus
  the situation and event chain panels' height (SetupSituationAndEventChainPanels; none here).
- The options: an `event_window_option_entry` each, at event_option_offset (x 7, 30 apart), the
  first at the frame's bottom + 5; the option's name on its button (the .gui's button has no
  buttonText: Setup sets it); no valid option: one, "event_option_error". The 476-wide button
  texture has 12 px of margin (the visible button starts at 19).
- Hidden: the tts button, the chain and situation panels, the presence icon. The focus button
  shows for an event with a `location`; without, the message settings button takes its x.
- The picture: the event's `picture` sprite in `event_picture` (450 x 150, centred at 130). The
  mean difference over it is 7 (1.5 to 3 on the texts), and most of it is horizontal scan lines
  the game draws over the picture: they are in none of the textures (the picture, event_frame.dds
  whose inside is transparent, event_stripes_texture.dds, a faint white band at alpha 0.1 that
  `stripes_1` scrolls), so they come from the sprites' shader **[I]**, not drawn here. The
  masking texture (event_mask.dds, the same for all 581 masked event pictures) only cuts 2,236 of
  the 67,500 pixels at the edges: not applied; the stripes' band not drawn either.
- Texts: wrapped at the text box's maxWidth (436), lines of the font's line height (cg_16b: 16),
  colour codes kept (render.windows.events `wrap`, measured with the renderer's font metrics:
  RENDER_FONT_METRICS). The title in malgun_goth_24.
- Which `title`, `desc`, `picture`: the first variant whose trigger holds
  (NEventWindowUtil::GetEventWindowDesc); on 2210.01.01 the player is xenophobe, so first_contact.1
  shows its "xenophobe" text, as the game does. Triggers: the simulation's evaluator when its
  scripts are loaded (load-sim), else a small one over the world (ethics, authority, civics,
  NOT/NOR/OR/AND/NAND, custom_tooltip, has_technology, has_modifier, is_homicidal; an unknown
  `x = yes` false) **[I]**.
- [Scope commands]: the names a text may ask for are made where the world is, from the event's
  scopes (this, root, from, fromfrom, the saved event targets) and one or two links on (owner,
  system, contact country, capital, species, leader): `This.System.GetName` "Gallamun",
  `This.ContactCountry.GetName` "Kappa Menace" (a country without communications is named by the
  player's relation's `pre_communications_name`). Others stay as text **[I]**.
- Which events: the save's `player_event` blocks of the player (`date` is the day it expires:
  first_contact.1's 2210.03.04, and the game drops it then **[V]** by `event` after 60 and 90
  days), and the events the simulation opens for the human player (simscript.events calls
  `opened`), shown at once and kept until closed or EVENT_AUTOSELECT_MONTHS (9) have passed.
  Choosing an option closes the window: the simulation has already taken the first valid option
  for the human, so no command is sent **[I]**.
- Measured: mean difference over the window 3.8 / 4.7 / 4.4 (RGB).

## The Situation Log (interface/situation_log.gui `situation_log`, CSituationLog)

- At its show_position (35, 40), 1008 x 690; the tabs at the bottom (Situation Log, Findings,
  Empire Focus, Victory: the active one's `_active` button) **[V]**.
- The list **[V]** parts, **[I]** spacing: the categories of common/situation_log/categories by
  priority, the Log tab those without `target_tab = anomalies`, the Findings tab those with it;
  a `situation_log_entry` header (category icon and name, the expanded arrow GFX_entry_expand
  frame 2), its entries as `situation_log_subentry` rows 44 apart (header to first row 39), the
  next category 8 below the last row; the selected row's `selected` overlay; no pin on the
  tutorials' rows **[I]**.
- Entries: the player's event chains (country `events`: common/event_chains' category, icon (a
  .dds), picture, counters; `<chain>_title`, `<chain>_desc`), special projects, situations, first
  contacts in progress (Findings), archaeological sites the player knows. A planet's `anomaly`
  is an anomaly not found yet (the game's Findings list none of them on 2210.01.01) **[V]**; the
  found ones are not read yet.
- The selected entry (the first when none is chosen **[I]**): its title, picture and description
  (wrapped at 235, the 130 px box's lines: the scrollbar not drawn), and its subview: an event
  chain's "Overall Progress:" and counters ("Galaxy Map Toggled: 0/1"); a first contact's
  requirement ("Assign an Envoy to learn more about Kappa Menace"), days until the roll,
  difficulty and "Show First Contact" (its places are @findings_* variables of another window of
  the file, out of reach of render.gui's scoped variables: given in situation.lua).
- A first contact's difficulty **[V]** (CSituationLogSubviewFirstContact::UpdateDifficulty):
  CFirstContact::GetCurrentStageDifficulty (the save's `difficulty` + CalcTargetDiscoveryMalus:
  the contact's country's intel_encryption_add x (1 + intel_encryption_mult)) less
  CalcDiscoveryBonus (the owner's intel_decryption_add x (1 + _mult)), at least 0 (the modifier
  types 0x17f..0x182 taken for these four **[I]**; the simulation's values: country 6's encryption
  2, the player's decryption 0, so 5 + 2 = 7 as the game's frame). Its tier
  (NGuiUtil::MapDifficultyToEnum: 0, 1, 2, more) gives the value's colour (GetDifficultyColor: G,
  Y, H, R) and the icon (GFX_firstcontact_difficulty_easy, _normal, _hard, _hell).
- The roll's bar: the days run of FIRST_CONTACT_DISCOVERY_DAYS (80) on
  GFX_situation_log_progressbar_research (empty at 80 days left: the game's start cap not drawn
  **[I]**); the days left, then £time£.
- The header's buttons: `track` (the pin) and `goto`; with goto hidden the pin takes its place
  (CSituationLog::UpdateTrackButtonPosition): an event chain shows the pin alone, a first contact
  both **[I: the frames]**. The header reads "Findings" on that tab.
- With an event window opened before the log, the game's frame shows no entry selected **[V]**;
  the renderer selects the first anyway **[I]**.
- Measured: Log tab 3.5 / 4.2 / 3.8, Findings 3.7 / 4.6 / 4.2.

## Discoveries (interface/discoveries_view.gui `discoveries_view`, CDiscoveriesView)

- The Relics tab: "Relics and Minor Artifacts"; the narrow relics box at 1600 wide **[I]**; relics
  found, the triumph text, a slot per relic and empty frames up to 6 (8 px right of the grid's
  place **[I]**: the frame); the other tabs hidden (DLC or unlocks: the frame has Relics alone **[I]**).
- Minor artifacts (CMinorArtifactsView::UpdateArtifactActionsGrid) **[V]**: the actions of
  common/artifact_actions whose `potential` holds (CArtifactAction::IsPotential), stably sorted
  by cost (SSortArtifactActions): the three `_locked` ones without a cost first ("??????"), then
  Sell to Private Collectors (50), then the 100s in file order, as the frame; a cost above the
  stockpile in red, no frame on the entries' button **[I]**; £minor_artifacts£ is the resource's
  icon **[I]**.
- Measured: 0.5 / 0.6 / 0.5.

## The first contact view (interface/first_contact_view.gui, CFirstContactView)

- Centred, 940 x 640; the contact's name, its event's picture (the save's contact `event = {
  picture index }`), a `stages_box_entry` per stage so far (the starter's icon, then the
  stage's, 53 apart **[I]**), the event's title, its description from the text list's top (no
  name), its options (`stage_event_option`, 35 apart), "Stage N" (STAGE_TITLE, N the event's index
  + 1 **[I]**), the species panel with the unknown portrait; the leader, progress, difficulty and
  modifier panels hidden for a contact without an envoy **[I]**.
- A window background's `position` moves it from the window's corner (render.gui, general **[V]**:
  the chapters frame at -58, -27 matches the frame to the pixel).
- "Show First Contact" closes the Situation Log (App::close_view) and opens the view, as the
  game: clicked in both, the whole frames differ by 3.9 / 4.2 / 3.9.
- Measured: 4.3 / 4.3 / 4.1.

## The buttons (render-buttons-1)

What each clickable element does, as the game does it, and how it was checked (S: the renderer's
command protocol; G: the same clicks on the headless game, its frames or `state`; W: the windowed
renderer under Xvfb with xdotool, 2210.01.01 from Load Game).

| element | what it does | state |
|---|---|---|
| event option | its effects in the simulation, then `after`, and the event no longer open (COpenPlayerEvent::OnOptionSelected: simscript.events `answer`, through views.rs `cmd` frame: `events_data.command("answer")`); a save's own `player_event` is taken out of the world | wired: S (clones.14's second option: influence 596.5 -> 496.5, the event gone; first_contact.1 answered and gone after a day) |
| an event the simulation fires for the player | kept open (simscript.events `defer`), its window shown at once; unanswered for EVENT_AUTOSELECT_MONTHS (9), its default option (the first valid) | wired: S (`event fire clones.14` opens it; 270 days later it is gone and no influence was paid) |
| RETURN | the top event window's first option (Setup gives it the shortcut) | wired: S |
| event focus button (Q) | NGuiUtil::FocusOnScope of the event's location: the system entered | wired: S, G (`state` view system 142 after the click, both) |
| event close (X) | the window closed, the event stays open (no shortcut: Escape does not close it [V .gui]) | wired: S |
| event window background | brought to the front (MoveToFront) | wired: S |
| message settings button | the message settings on the event's message type (Setup's lambda 0x2d330b0: CMainMenuView::ShowMessageSearchFilter, the type's setting name): the Settings window's Messages tab filtered to it (message_settings.lua, below); its checkboxes, Reset Default, Discard Changes, Apply & Close, Cancel and Escape; a fired event opens its window only when its type's popup is on and pauses the game when its auto-pause is (events.rs) | wired: S, G (the window against the game's frames: below; a click on Popup leaves it ticked in both, on Auto-Pause unticks it), W (the test save `ev_test.sav`: clones.14 on 2210.01.05 opened and paused; its settings, Auto-Pause off, Apply & Close, the event answered; the next clones.14 opened with the game running, 2210.03.04 at normal speed). The game's side of a fired event is not checked: view mode never runs time, `step` skips the message system |
| Situation Log tabs (Z, X) | Log, Findings | wired: S, W (Empire Focus and Victory: not laid out) |
| a row | selects the entry | wired: S, W |
| a category header | folds or unfolds a collapsible category (the arrow's frames 1 / 2) | wired: S, G (same frames), W |
| a row's pin | the entry to "Priorities" and back (GFX_button_pin_pinned), kept by the simulation (`cmd:events_data:pin:KIND:KEY`, events_commands' `pinned`) | wired: S, G (1.7 / 2.3 / 2.0 against the game's frame), W (the test save's Energy Shortages to Priorities) |
| track | the selected entry tracked (CTrackSituationLogEntryCommand: `cmd:events_data:track:KIND:KEY`, its dot in the list) and its tracker on the galaxy map (events.rs `draw_trackers`, below) | wired: S, G, W (first contact 19 tracked: the orange hexagon at Gallamun, the size of the game's at the distances 200, 600 and 3000) |
| goto | the galaxy over the entry's system, at the distance the game leaves a system with (the camera's goal: with the window's smooth camera show_galaxy starts at distance 0.001) | wired: S, G (galaxy, target 97.44 162.96 in both), W |
| close (Escape) | the view closed (no side windows: `escape_keys = {}`) | wired: S, W |
| Show First Contact (RETURN in its subview) | the first contact view; the log closes | wired: S, G, W (the RETURN shortcut not wired) |
| first contact view option | the contact's open event answered (as an event option), the view closed | wired: S, W |
| first contact view goto | the galaxy over the contact's system [I: as the log's goto] | wired: S |
| first contact view close (Escape) | closed | wired: S |
| first contact view, answered | "Nothing to report" (no_report_icon, no_report_text), no text or options [I] | wired: S |
| Discoveries row (artifact action) | CArtifactActionCommand: when its potential and allow hold and the stockpile pays it, the cost paid (the stockpile, as empire_commands' pay) and its effect run in the simulation (`cmd:discoveries:artifact:KEY`); otherwise the row takes no click (no button shown) | wired: S (`event effect add_resource = { minor_artifacts = 200 }`, Sell to Private Collectors: artifacts 200 -> 150, energy 9084 -> 9584, the row then off by its cooldown), W (the test save: 200 -> 150, energy 9.0K -> 9.5K) |
| Discoveries tabs (Z), close (Escape), left bar | as the views frame | wired: S, W |
| relic slots | CRelicGridEntry::Activate posts CActivateRelicCommand (no popup): when the relic's `possible` holds and the stockpile pays its activation_cost, the cost paid and its active_effect run (`cmd:events_data:relic:KEY`); the triumph (relic_activation_cooldown) then shown, "Triumph Active For: £time£ N", the slot's frame GFX_relics_frame_active | wired: S (r_khans_throne granted by `event effect add_relic = r_khans_throne`: unity 3131 -> 131, drums_of_war and relic_activation_cooldown 3600 days, a second activation refused), W (the test save's relic: unity 3.1K -> 131, "Triumph Active For: 3600") |
| popups (OK RETURN, Decline ESCAPE) | closed | wired; no button of these windows opens a popup.gui popup in the game [V: the callers of CPopupMessage's constructors are the planet, fleet order, load/save and federation views and CGameState::HandleTurnTick's debug "Run Finished"], so none is opened here |
| situations' approaches | a `situation_approach_entry` per approach whose potential holds (165 apart, centred, 4 a row), the current one selected, one not allowed greyed; a click sets it (CSetSituationApproachCommand: `cmd:events_data:approach:SID:KEY`, its cost paid, on_select run) | wired: S (`event start_situation situation_energy_deficit`: situation 12, progress 15, the approach switched), W (the test save's situation 100: Cut Scientific Investment selected) |

Commands added for these checks: `event fire NAME` (the game's console `event NAME`: the event
fired for the player in the simulation), `event influence`, and (renderer, the simulation's
world; events_commands.lua):

| command | |
|---|---|
| `event effect TEXT` | an effect run on the player's country (`add_resource = { minor_artifacts = 200 }`, `add_relic = KEY`: the engine has no add_relic, events_commands adds it [I]) |
| `event start_situation TYPE` | a situation of common/situations started for the player (its start_value or initial_progress, the stages' ends, the default approach; on_start run) |
| `event stock RES` | the player's stockpile of RES |
| `event approach SID KEY`, `event relic KEY` | as the buttons |
| `event modifiers` | the player's timed modifiers (`KEY:DAYS ...`) |
| `event modifier KIND:ID NAME` | a scope's modifier value in the simulation (`event modifier country:6 intel_encryption_add` -> 2) |

The real-window test saves (W, on .24, listed by Load Game with `STELLAR_SAVE` pointing at one):
`/root/ev/saves/sit_test.sav`, 2210.01.01 with a `situation_energy_deficit` situation (100) for
the player, r_khans_throne in its relics and 200 minor artifacts; `/root/ev3/saves/ev_test.sav`,
2210.01.01 with two delayed `clones.14` for the player (its standard_event_module's
`delayed_event`, 3 and 20 days: the simulation loads them, engine.script.event_save), so events
fire in the window once it runs.

## The tracker on the map (gfx/pingmap, CPingMapManager)

- A tracked entry (first_contact_tracker, situation_tracker ...: all with `galaxy_entity =
  project_tracker_galaxy_effect_entity`) is the particle project_tracker_galaxy_effect_particle at
  its system: `flare` (gfx/particles/hexagon.dds, the hexagon's corner brackets, 255 150 0,
  additive, size 15) and `halo` (size 50 grown over its life by `grow`, faded by `fade_alpha`).
- Its size follows the camera: the ping's `galaxy_normal_zoom = 400`, the entity's scale 1 at the
  game's distance 400, so the same size on the screen at every zoom. The game's frames
  (`headless/view.sh`, 1600 x 900, distances 200, 600, 3000): the flare's brackets about 60 x 55
  px; the renderer's 67 x 60 at its 100, 300, 1500 (the map's units are half the game's).
- The halo pulses in the game; the renderer draws particles as a steady state (each at a random
  age: render/particles.rs), so one ring. The game showed the tracker only some 10 s after goto
  **[I: its ping's start]**; the renderer at once.
- Its file writes `life`, `size` and `size = 50.000,grow` as plain numbers, not blocks:
  render/particles.lua read only blocks, so the tracker (and the other particle files' such
  subsystems: 776 files write one) had no particles. It reads both now; the system views' star
  effects use blocks (unchanged).

## The message settings (interface/settings_view.gui `settings_view`, message_settings.lua)

- The Settings window on its Messages & Alerts tab (`video_button`'s frame 2 in the file put back
  to 1, `message_tab_button` 2), the Messages sub tab, the search text, a `message_settings_entry`
  per matching type. Against the game's frame of event 53's settings button: the tabs' labels 1
  px off (their `text_offset`: render.gui now applies it, centred in the sprite's frame unscaled
  for a scaled button: settings_view's sub tabs at 0.75 with -30, -12 move 1 px right and 5 up, as
  the game's **[I: only with a text_offset]**), the search text at its edit box's borderSize (46)
  exact, the entry's checkboxes exact.
- From the game's frames: Popup Auto-Unpause ticked (its default setting **[I]**), the filters'
  All radios selected (GFX_radio_button frame 2), FILTER_CATEGORY_HEADING whole (a fixedSize box
  without maxWidth), Reset Default greyed before and after a change not applied (greyed here while
  the applied settings are the defaults **[I]**), no edited mark until applied.
- Types with `hidden_in_message_settings` (EMPIRE_FOCUS, ENCLAVE_DIPLOMACY, the terraforming
  candidates: the events' other message types) are not listed; a type's title is its
  message_setting_key, its `name`, else MESSAGE_<KEY>_TITLE; the filter matches a title without its
  scripted parts ([Scope.GetX], not resolved here: the galactic council's types).

Script gotchas, the views' data: in lockstep (`timestep`) a view's data waits for the
simulation's snapshot, which may come long after; without `timestep` the commands wait for it.

Script gotchas: in lockstep (`timestep`) a click needs a `move` there a few frames before (the
button is taken from the hover), and a second click at the same place within 500 ms is a double
click; after `open_view` the view's data arrives with the next snapshot.

## Not done

- The event picture's mask, the event chain and situation panels of the event window, the second
  stage icon's state and the unknown silhouette; the description's scrollbar; the roll bar's
  start cap.
- The popups (popup.gui `ok_popup_window`, `yes_no_popup_window`) are laid out by events.lua, but
  no game frame of one was taken (CPopupMessage's placement not read) **[I]**; these windows open
  none (above).
- The anomaly, archaeology and astral rift views: the 2210.01.01 player has no found anomaly, dig
  site or rift, so there is no game frame to check them against; not laid out.
- The situation subview: no game frame (a situation needs a modified save): the progress bar, its
  pin and the approaches are laid out [I]; the stage icons, the details' effects and the outcomes
  are not. The month's change is not computed (the simulation does not advance situations).
- The message settings: the settings are the renderer's, not kept between runs (the game's are
  in its settings file); the search box is not editable and its background not drawn; the
  filters' radios and Popup Auto-Unpause take no click; the notification and toast settings change
  nothing (no notifications or toasts).
- The tracker's halo pulse (the particles' time).
- The Empire Focus and Victory tabs; the Discoveries' Collection, Vivarium and Astral Actions tabs.
