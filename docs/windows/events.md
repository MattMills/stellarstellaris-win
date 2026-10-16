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

## Not done

- The event picture's mask, the event chain and situation panels of the event window, the
  difficulty's modifiers (the game shows 7 for the save's 5), the roll's time bar, the goto
  button's sprite in the Log tab, the second stage icon's state and the unknown silhouette.
- The popups (popup.gui `ok_popup_window`, `yes_no_popup_window`) are laid out by events.lua, but
  nothing in the renderer opens one yet and no game frame of one was taken (CPopupMessage's
  placement not read) **[I]**.
- The anomaly, archaeology and astral rift views and the situation subview: the 2210.01.01
  player has no found anomaly, dig site, rift or situation, so there is no game frame to check
  them against; not laid out.
- The Empire Focus and Victory tabs; the Discoveries' Collection, Vivarium and Astral Actions tabs.
