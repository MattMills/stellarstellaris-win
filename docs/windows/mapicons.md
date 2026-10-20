# The map icons (interface/mapicons.gui)

The galaxy's star labels (`star_mapicon`, CGalacticObjectMapIcon) and a system's fleet, station
and planet labels (`fleet_map_icon`, CFleetMapIcon; `planet_map_icon`, CPlanetMapIcon), bound to
the save. **[V]** read in the 4.5.2 Linux build (addresses below) or measured in the game's
frames; **[I]** inferred.

Code: `sim/render/lua/render/windows/mapicons.lua` reads the world's facts (owners, capitals,
starbases, fleets, deposits and the stations that collect them, the player's surveys,
communications and first contacts; read with the galaxy: `Galaxy::mapicons`);
`sim/render/src/mapicons.rs` applies the game's rules for an observer and builds the labels
(`App::galaxy_labels`, `App::system_labels`, moved out of app.rs); render.gui lays them out and
scene::add_labels places and stacks them.

## Who looks: the observer

The player's country, or none after `observe` (OnExecute_Observe gives the local human no
country). Two different notions of "communications" are used by the game:

- CCountry::HasCommunications (the fleets' icon type, the resources' visibility): the observer's;
  none when observing, so every fleet shows as "?".
- NUtil::HasPlayerCommunicationsWith (the capital plate) **[I]**: the player's even when
  observing (the observe frames show the player's capital plate, not others'). The owner's flag
  is drawn for the same countries only **[I: observe frames: enclaves' and empires' plates
  without flags]**.

## Star labels (CGalacticObjectMapIcon::Update, 0x3536930)

The order of Update: UpdateName, UpdateOwner, UpdateResources, UpdateSystemFleets,
UpdateStations, bypasses, intel, the research icons (anomalies, special projects, colonizable
planets), magnet, inhibitor, logistics hub, claims, sectors, hover, debug, espionage, first
contacts, contracts. SetUpData (0x3536510) fills the update data:

| field | meaning |
|---|---|
| +0x08 | the observer (GetLocalObserved) |
| +0x10 | the controller: the primary starbase's controller when the system shows a shield (+0x1376, below) and the observer is none, or has lifted its terra incognita there or has communications |
| +0x20 | the observer's intel level of the system |
| +0x21 | zoomed out: the camera's zoom above NCamera.GALAXY_SHOW_STARNAME_ZOOM (800 world, 400 map units) |
| +0x22 | the hovered system |
| +0x23 | show the name: intel > 0, not zoomed out, ShouldDisplayNameForCountry |

Which systems get a label: ShouldShowIconForGalacticObject (0x3531480): not inside a system view;
the observer's intel level above 0 (here: the terra incognita's systems; all when observing), or
contracts there. All map labels keep their pixel size at every zoom **[V]**.

- **The name** (UpdateName 0x3533f40) **[V]**: shown with +0x23; its colour (SetModColor):
  white where the observer has fully surveyed the system, grey 0.5 where not; restricted
  systems red (1, 0.25, 0.25) / (0.75, 0, 0) (IsSystemRestricted, not read).
  CCountry::HasFullySurveyedSystem (0x237acd0): true for the country's own system, else every
  planet (and astral rift **[I: not read]**) surveyed; a planet is surveyed
  (_HasSurveyedDepositHolder 0x237aea0) when its owner or controller is the country or it is in
  surveyed_deposit_holders; always when observing. A new game's empires have their home system
  surveyed: NGalaxyGenerator::CreateStarbaseWithDesign calls CCountry::AddSurveyedSystem (the
  game's 2200.01.11 save lists the home system's planets 0 .. 12); the Lua generator writes that
  list (engine/newgame/empires.lua).
- **The owner** (UpdateOwner 0x35338d0) **[V]**: only with +0x23 and a valid controller. The
  shield (CGalacticObject +0x1376, CalcShouldDisplayShieldOnMap 0x25fc740): a starbase whose
  level has display_empire_shield (or is occupied), or a colony in the system; outposts show no
  plate. Then:
  - the plate `name_bg` (or `name_bg_capital` for an empire's capital or a sector's capital,
    when HasPlayerCommunicationsWith) fitted to the name: width = text width + the plate's
    height (18, 22), x = -(width / 2 + height / 2) in whole pixels; its colour
    GetDiplomaticRelationColor (the player's green; neutral grey; the selected gold);
  - the flag `star_owner` at star_mapicon_icon_offset (-37, 7) less half the text width (the
    capital's `star_owner_capital` at star_mapicon_icon_offset_capital (-40, 3)), and for a
    capital `flag_capital_decoration` at the flag + flag_capital_decoration_offset (-3, -1),
    frame 2 - (empire capital) (1 an empire's, 2 a sector's), scaled by
    FLAG_CAPITAL_DECORATION_SCALE (not in the defines: 1 assumed **[I]**);
  - occupation (star_owner_occupied, the big frame offsets) not drawn.
  - A system whose starbases list names none that exists and that has a military or observation
    station (guardians, enclaves: Belgium) shows a
    plate in grey 0.22 without a flag **[I: the observe frames; the null starbase's level is not
    read]**.
- **Resources** (UpdateResourcesThreaded 0x3534410, UpdateResources 0x3534ba0) **[V]**:
  CGalacticObject::ListResourcesForMapmode sums the deposits of the system's planets the observer
  has surveyed (owned and controlled planets count as surveyed; colonies excluded) into three
  tables (CDeposit::ListResourcesForMapmode 0x2487640): not collected, collected by the
  observer's station, collected by another's. A deposit is collected when the planet's
  `shipclass_orbital_station` fleet is of the deposit type's station class or a starbase.
  Each resource (common/strategic_resources' order) is a `resource_icon_item` whose `num` is
  built from colour codes:
  - Normal: the uncollected sum in white (`§W`), where the observer may see it
    (NeedsBorderAccess: unowned systems, its own, owners without communications); a resource
    with nothing uncollected is left out.
  - Details (`b00`: the system hovered, or CInGameIdler::IsMapFilterEnabled(1): the bottom bar's
    Details Map Mode filter at "Detailed", or **Alt held** (`TOGGLE_MAPMODE_DETAILS_TEMP`, "Hold
    Alt to toggle Details temporarily")): the three sums each on a line of its own, uncollected
    white `§W`, the observer's green `§G`, others' yellow `§Y` (`§H` instead for hindered
    deposits, CollectHinderedResources **[I: not done]**).
  - Hidden (the filter's third state, IsMapFilterEnabledInternal(4), unless Details): none.
  Here: mapicons.rs resource_rows and App::resource_mode (Alt from the controls' held keys, the
  filter from mainbars.rs); the labels are laid out again when the mode changes. Checked against
  the game on 2200.01.11 (the home system: `2 2 2`; Alt: `2 2 2` over green `10 10 3`) and on a
  new game made here (Sol: white `2 2 2` energy, minerals, engineering; Alt: green `10 10` and
  physics `3`). Hidden zoomed out and at intel 0. Layout: `resources` box (-88, 35), 176
  wide, centred; the items step 18 px (spacing 8 + the item counted 10 wide **[I: measured]**).
- **Fleets** (UpdateSystemFleets 0x3536b40) **[V]**: within GALAXY_SHOW_FLEETS_ZOOM (2300 world,
  1150 map); the fleets of the classes military, constructor, colonizer, science, transport,
  military special, gravity snare, entropy conduit (mask 0x381f) and mobile starbases; not to be
  killed, mobile; the observer sees them (CanSee; here: its own, and where its systems or fleets
  are or one jump from them **[I]**). One `star_fleet_entry` per (relation, icon type), relation
  major (NGalacticObjectMapIcon::CUpdateCache), in `fleets` from (10, -15), 23 px apart:
  - relation (CFleet::GetFleetRelationType): 0 own, 1 neutral, 2 allied (not read), 3 hostile
    (the owner's country type faction hostile, or no communications with it **[I: an uncontacted
    empire's fleet is red]**; wars not read); every fleet is neutral to an observer;
  - icon type (GetFleetIconType 0x294de40): 0 without communications ("?"); military: its power
    tier 1..7 by NInterface.FLEET_ICON_POWER_TIERS (set by no defines file: the empty array's
    storage reads 343.02.. **[I]**); science 8, constructor 9, transport 10, colonizer 11,
    military special 13, entropy conduit 15;
  - the presence icon GFX_fleet_presence_icons frame 1 + relation (+4 in FTL; +8 selected), the
    overlay GFX_fleet_presence_overlay_icons frame 1 + (type x 4 | relation), hidden for a gravity
    snare (NMapIcon::UpdateFleetMapIcon).
- **Stations** (UpdateStations 0x3537170) **[V]**: in `stations` from
  star_mapicon_stations_offset (5, 7) + half the text width, 28 px apart:
  - the starbase (CGalacticObjectMapIconStarbaseItem::UpdateWithData): its level's
    display_map_icon (outposts: no) or a colony of its owner in the system, and its ship size's
    icon_frame above 0 (GFX_starbase_ship_size_small);
  - station fleets (ShouldShowIconForFleet 0x3541400): at full intel military, observation
    stations and starbases (classes 7, 9, 10); the frame CFleet::GetIconFrame (0x294a080): owner
    type cases (18, 19, 38/39; 21 for a country-type flag with the fleet's flag 4: the enclaves'
    tower **[I: enclave types]**), class 10 carrying no colony 31, gravity snare 55, else
    GetShipClassIconFrameFromSize.
- **First contacts** (UpdateFirstContactIcons): `contact_item` in `contacts` (10, -31), its
  button at (-25, -10): the player's first contacts in progress at the system.

## EShipClass and the type icons

EShipClass (GetShipClassTokenFromEnum's token table, names from GetTokenArray) **[V]**: 0
military, 1 constructor, 2 colonizer, 3 science ship, 4 transport, 5 mining station, 6 research
station, 7 military station, 8 habitat station, 9 observation station, 10 starbase, 11 military
special, 12 gravity snare, 13 entropy conduit. GetShipClassIconFrameFromSize (0x317e000): the
size's ship_class_icon_frame when set; else class 7 → 27, a mobile starbase → 31; else
(3, 2, 14, 1, 15, 7, 9, 1, 6, 13, 8, 28, 1, 62) by class. The system view's fleet labels use it
(the fleet's class from the save's `ship_class`); the old by-eye frames for science and
colonizers were wrong.

## System view labels

- **Fleets**: the shield bar on all but the orbital stations (mining, research, habitat,
  observation) **[I: frames]**.
- **Planets** (CPlanetMapIcon::UpdateName 0x3524d70, NMapIcon::AdjustNameBg 0x35006d0,
  AdjustFlagButton 0x35008c0) **[V]**: w = the name's width in whole pixels; the plate
  (w + planet_map_icon_bg[_capital]_size_offset 23) wide, x = -width / 2; left of the name
  (flag, flag_capital, flag_capital_decoration, health, colonizable): x = -w / 2 less the
  element's own width + `planet_map_icon_<name>_offset`, y the offset's; the icons (decoration,
  health) count no width **[I: measured]**: flag (-14, 7), flag_capital (-12, 3), decoration
  (-55, 3), health (-17, 11); right of it (type, type_bg, type_bg2, flag_controller, arch site)
  x = w / 2 + the offset.

## The overlapping boxes (COverlappingElementsBox::UpdateGraphics 0x43bf6b0) [V]

The step is the first element's size + `spacing` (read as an integer; default 1); when n items
do not fit, step = (box - element) / (n - 1); format left (the default), right, centre (the
offset rounded). The type's `format`: `center`/`centre` centre, `left`, `right`.

## Compared (2210.01.01 save, 1600x900, game left)

- Galaxy at the default camera (`view galaxy`, distance 100): the home label (capital plate,
  flag, decoration, starbase icon, fleets "military, science, constructor", resources 2 2 2)
  pixel for pixel but the resource icons ±1 px; the grey unsurveyed names of Gallamun, Toarus.
- Mid zoom (175) and far (350): labels keep their size; names and resources hidden past 400.
- `observe` at (117, 182) d 100 and (-150, 60) d 120: every known system's name, resources, "?"
  fleet icons, no plates on outposts, the enclave's (Belgium) plate and tower.
- The home system view: fleet type icons, shield bars, the capital planet's flag, decoration,
  health bar and plate.

## Not done yet

- The research icons left of the star (colonizable planets: habitability; anomalies; special
  projects), the first contact icon's sprite check, intel, hover indicator, claims, sectors,
  bypasses, logistics hubs, magnets/inhibitors, debug and espionage icons.
- Other station types' frames (Hodranva's station icon in the observe frame), occupation.
- CanSee (sensor ranges), wars and alliances in the relations, the military power tiers.
- The planet health bar is drawn as a plain sprite, not the progress bar (full/empty textures).

## Clicks on the map (branch wire-map)

Read in the 4.5.2 Linux build and checked in a real window (Xvfb, the windowed renderer) and
against the game's clicks (headless view mode):

| input | the game | here |
|---|---|---|
| left click on a fleet label's plate (`bg`; on the galaxy its presence icons) | selects the fleet (CFleetMapIcon::OnReload binds bg, fleet_icon, fleet_type) **[V]** | wired |
| left click on a fleet label's flag | nothing (no observer) **[V]** | nothing |
| left click on a planet label's plate, capital plate, type frame | selects the planet, opens its view (CPlanetMapIcon::OnReload: bg, bg_capital, type_bg) **[V]** | wired (type_bg added) |
| left click on a planet label's flags | nothing (flag, flag_capital: no observer) **[V]** | nothing |
| left click on a star label's plate | the camera slides to the system (CGalacticObjectMapIcon::OnBGClicked -> SlideCameraToSystem); no selection **[V]** | wired (`map:slide:I`; it selected the system before) |
| left click on the map | DoSelection / GetSelectableAt: the nearest ship or planet along the ray in a system, a system on the galaxy **[V]** | as before (scene.pick_at) |
| left drag (4 px) and release | GetSelectablesForDragSelection: the fleets in the box, FilterSelectionList (the player's mobile fleets first) **[V]** | the first of them selected **[I: one selection here]**; no box drawn |
| right click | PerformAction / PerformRightClickActionAt **[V]** | the selected mobile fleet of the player's: to a planet (orbit_planet_order), a system (galaxy), a point of the system's plane (move_to_system_point_order), the fleet's orders replaced, through the simulation (engine.fleets.orders, Clock::query); the right-click menus and other targets not done |
| double click | GetSelectableAt, FocusOn **[V]** | as before |
| Escape, nothing open | the game's menu window (button_topbar_menu) **[I]**; the view stays (two Escapes in a system view leave it there in the game's frames) | logged, the view stays (it went to the galaxy, then to the main menu) |

Fixed in the window path:
- **The system camera after a load**: the window loads the save behind the load screen and
  enters the capital's system before the simulation has sent its bodies; the camera was fitted
  to Map::system_data's stand-in (outer_radius 100 instead of 370): the view 3.7 x closer than
  the game's, every label and pick elsewhere than in the game. It is fitted again once the system
  comes (App::refit_system_camera).
- **A resize or a maximise** panicked in wgpu (the last scene's depth buffer, of the old size,
  with the new swapchain image). A scene of another size is not drawn: the image is cleared and
  presented until the UI thread's scene of the new size is up (an image taken and not presented
  is never given back by lavapipe's X11 swapchain: the surface then timed out for good).
- Cursor coordinates: winit's CursorMoved and Resized are both physical pixels, the app's size
  follows Resized, the GUI is laid out and picked at that size: under a resize the clicks select
  what is drawn under them (checked at 1600x900 -> 1280x720 -> 1600x900).

Not done: the box's rectangle while dragging, several selected fleets, the right-click menus.

## The hover marker and display scaling (branch map-hover)

**What the game draws under the cursor** (its frames, headless view mode, the 2210.01.01 save):

| the cursor over | the game | here |
|---|---|---|
| a star on the galaxy | the star label's `hover_indicator` (CGalacticObjectMapIcon::UpdateHoverIndicator [V]: GFX_map_icon_system_enter, `system/system_enter.dds` 70 x 47, the hexagon and the eye, at (-35, -23): about the star), while the system is CInGameIdler's hovered one (idler+0xaa4, the star the ray picks) | the same: App::hovered_system, the labels' key has it |
| a star's name, a label's part, empty space on the galaxy | no marker (the frames: the name 24 px under the star shows none) | none |
| a planet, a planet's label, the star, a ship in a system | no marker; a tooltip only | none (tooltips not done) |

[I]: the sprite's other frames (`system_enter_cant`, `system_goto_cant_has_intel`, the jump
drives', chosen by the selected fleets' possible orders) and the idler's flag at +0xe88 that hides
it; whether a hovered fleet on the galaxy marks its system.

**Display scaling** (Windows at 125 % or 150 %): everything is in physical pixels: the window is
made with a PhysicalSize, the surface and App::size follow Resized, CursorMoved is physical, the GUI
is laid out and picked at that size; the scale factor changes no coordinate (the window logs it at
start, `window: WxH pixels, display scale S`, and on ScaleFactorChanged, after which winit resizes
the window and a Resized follows). Checked in a real window under Xvfb with
WINIT_X11_SCALE_FACTOR=1.25 and 1.5 (logged as such), at 1536x864: the load screen's buttons, a
planet label (planet 5 selected), a fleet label (fleet 3), an empty click (nothing selected), then
a resize to 1280x720 (the bottom bar's galaxy button hit at its new place), then 1920x1080 (the
hover marker under the cursor at the window's centre). The GUI is laid out at the game's scale
1.0 whatever the display's scaling.
