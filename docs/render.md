# The renderer (4.5.2): the galaxy map, the front end, localisation, fonts, the GPU backends, 3D

What the renderer (`sim/render/`, package `stellar-render`) needed to learn about the game's data
to draw the galaxy map of a save, the main screen's top bar, the main menu and the load game window,
the galaxy in 3D, a system with the game's models, and what was learned about the GPU backends on
the machines it runs on. The code: `sim/render/src` (Rust: textures, fonts, borders, meshes, the
camera, the GPU, the checks, the command protocol), `sim/render/lua/render` (Lua: what is read from
the game's files and the save, the GUI layout, the model definitions, a system's contents),
`sim/lua/engine/localisation.lua` (the texts, shared with the engine).

**Sources and marks.** No disassembly was used for this work: everything here was read in the
game's data files (`common/`, `interface/`, `gfx/`, `flags/`, `localisation/`, the shaders in
`gfx/FX`), in the saves, and checked by rendering. **[V]** marks what was read in the game's files
or saves (the file is named), or confirmed by a string in the game's executable (Steam 4.5.2 build,
`tmp_sym/steam452.exe`; the string is quoted), or measured by the renderer's own checks. **[I]**
marks what is inferred: the renderer's choice where the files do not say, or a reading of how the
engine uses data that the engine's code was not checked for. There are no function addresses: the
engine functions that draw the map and the GUI are still to be found in the GOG build (open
questions at the end). The exception is section 10 and the `headless/view.sh` driver: the 3D
camera, the scales and the display coordinates were read in the Linux 4.5.2 build's code (its
symbols name every function: CGameCamera, CCamera::UpdateMatrices, CPlanet::CalcCurrentEntityScale,
CCelestialCoordinate::GetDisplayCoordinate; the field offsets from that code, the Linux layout),
and checked against the game's own frames and values; **[V]** there also marks those.

Machines: `10.5.0.24` (Linux, GeForce GTX 1080 Ti (GP102, Pascal, 11 GB) with nouveau and NVK, Mesa
26.0.8, since 2026-10-15; game data in `/opt/stellaris`, saves in
`/opt/stellaris-saves`), the Windows laptop (Radeon RX Vega M and Intel HD 630; the Steam install).

## In short

- **A system's owner is not in the save's system block.** It is the owner of the system's
  starbase: `galactic_object.starbases` -> `starbase_mgr.starbases[id].station` (a ship) ->
  `ships[id].fleet` -> the country whose `fleets_manager.owned_fleets` lists that fleet **[V]**
  (save 2210.01.01: all 128 starbases resolve; 123 owned systems, 17 owners). Now indexed by the
  engine as `world.system_owner`.
- **Map colours** come from `flags/colors.txt`'s `map` swatch of the country's flag colour names
  (`country.flag.colors`, slot 0 primary, slot 1 secondary) **[V]**, not from
  `common/named_colors` (the fallback).
- **The galaxy map's art is named by the engine**, not by a .gfx: `gfx/map/star_classes/%s.dds`,
  `gfx/map/dust.dds`, `gfx/map/galaxycolor.dds`, `gfx/map/center.dds`, `gfx/map/nebula*.dds` are
  strings in the executable **[V]**. Hyperlanes are procedural (no texture), coloured by
  `NGraphics.HYPERLANE_DEFAULT_COLOR` **[V]**.
- **The main menu is `frontendgui` in `interface/frontend.gui`** **[V]**; its background is a
  render target of a 3D scene (`GFX_frontend_animated_bg`, effect
  `buttonstate_rendertarget.shader`) chosen in `common/frontend_backgrounds` **[V]**. The renderer
  draws the scene's backdrop texture as a still **[I]**. 4.5.2's front end has no Continue button
  (no `*.gui` in `interface/` names one) **[V]**; that the launcher's "Continue" stands for it is
  **[I]** (the launcher was not looked at).
- **The GUI layout rules** needed: anchors (`orientation`, `origo`), `margin`, percent sizes,
  scoped scripted variables, `if_scaled_resolution`, frame strips (`noOfFrames`), nine-slice
  cornered tiles, `buttonText`, `vertical_alignment`, `text_color_code` (section 3). Most are
  **[I]** (the rules that make the files' layouts come out as the game shows them).
- **Localisation** is Paradox yml under `localisation/<language>/`, 150,206 English keys in 232
  files; `$KEY$` references, `§X…§!` colour codes, `£icon£` icons and `[…]` commands in the texts
  **[V]**.
- **Fonts** are bitmap fonts (AngelCode BMFont text `.fnt` + a page texture) declared in
  `interface/fonts.gfx`, with TrueType overrides only for some languages **[V]**.
- **Every DDS in `gfx/` and `interface/` decodes on the CPU** with `image_dds`: 21,340 files in
  seven formats, no BC7 or DX10 headers **[V]**.
- **Backends:** Vulkan on Linux (NVK on the GTX 1080 Ti renders correctly); DX12 on Windows by default,
  because the laptop's 2018 AMD Vulkan driver (`amdvlk64.dll` 9.2.10.20) crashes when presenting
  and draws no hyperlanes, and its Intel Vulkan driver dies at start **[V]** (measured).
- **Meshes** (`gfx/models/**/*.mesh`) are a binary tree of objects and typed properties (`@@b@`,
  section 7) **[V]**: all 2,968 files read, 15 million vertices, skins of up to 4 bones per vertex,
  LODs in 5 files. **Entities** (`.asset`) name pdxmeshes (`.gfx`) with per-shape textures and
  shaders, attach entities at locators and clone others; 6,347 of 7,953 load as models, and 18,593
  of their 18,596 textures are found **[V]**.
- **The game's mesh shaders are in `gfx/FX`** **[V]**: the normal maps keep x in green and y in
  alpha (blue: emissive), the specular maps specular, metalness and glossiness in green, blue and
  alpha; the atmospheres are drawn on the back faces of a larger sphere; the stars are lava over
  noise with colours from `gfx/worldgfx` (section 8). The renderer ports these, without shadows,
  bloom or tone mapping.
- **3D, calibrated against the game's own frames**: the game's camera (CGameCamera: an orbit
  camera, left-handed, a 35 degree field of view), a system's scale (its world is the map x 10,
  its bodies at -150, each scaled by CPlanet::CalcCurrentEntityScale), ship placement and facing
  match the real game's frames from the same commands; the galaxy with star billboards, dust,
  nebulae, borders, lanes and FTL trails, a system view with the game's meshes, and single models
  (section 10). The post effects, sky, stars, planets, galaxy view and ships follow the game's
  shaders and look close to its frames (section 11's table); not yet: animation, the lens flare,
  the map's names. The window's controls (the clock, the camera, the selection): section 12.
- **Headless, driven by commands** over TCP or from a script, one reply per command after it
  completes (section 9); the real game speaks the same protocol (`headless/view.sh`), so one
  script takes the same shots of both.

## 1. The galaxy map from a save

### Systems, hyperlanes, owners

| what | where in the save | notes |
|---|---|---|
| position | `galactic_object[id].coordinate = { x y }` | map units, the galaxy's centre at 0,0; also `origin`, `randomized`, `visual_height` (unused) **[V]** |
| star | `galactic_object[id].star_class = "sc_g"` | -> `common/star_classes/<key>`: `class = g_star`, `icon_scale` (black holes 2, pulsars 2.25, neutron stars 1.5) **[V]** |
| hyperlanes | `galactic_object[id].hyperlane = { { to = id length = n } ... }` | written on both ends: 853 lanes, none one-sided, none to an unknown system **[V]** |
| owner | (none) | via the starbase, see above **[V]**; 4 systems list more than one starbase, always of one owner **[V]**; fleets have no `owner` field either **[V]** |
| country | `country[id]` | ids are versioned (`16777225` = index 9, generation 1) **[V]** |
| player | `player = { { name = "unknown" country = 0 } }` (top level) | **[V]** |
| date | `date = "2210.01.01"` (top level, quoted) | **[V]** |

The map is drawn with the save's x growing to the left and its y growing downwards: the galaxy as
the game's camera shows it from above at yaw 0 (its view is left-handed: screen right = world -x,
screen top = world -z, the world being the map x 2) **[V]** (CGameCamera, checked on the game's
frames, section 10). Until the reference shots the 2D map had y growing upwards (a mirror of the
game's map, the convention of save viewers such as Stellaris Dashboard).

### Colours

- `country.flag.colors = { "teal" "dark_teal" "black" ... }`: colour *names* **[V]**. The
  executable carries a doc string: "Four color swatches (keys from flags/colors.txt). Slots:
  0=primary (red), 1=secondary (green), 2=tertiary (blue), 3=ship color" **[V]**.
- `flags/colors.txt`: `colors = { name = { flag = rgb {...} map = rgb {...} ship = rgb {...} } }`;
  its header says `map` is the "color used on the galaxy map for territory borders and fill"
  **[V]**. 72 swatches. `common/named_colors` (`name = { color = { r g b a } }`) is the fallback
  for a name colors.txt lacks (none in the 2210 save) **[I]**.
- Colour blocks appear as `{ r g b a }` and `rgb { r g b }` in 0..255, `hsv { h s v }` and
  `hsv360` **[V]**; floats in 0..1 are read as such **[I]**.
- Borders: `gfx/FX/border.shader` (`PixelShaderSDF`) mixes `PrimaryColor` in the saturated band at
  the edge and `SecondaryColor` inside: `vColor = vAlphaEdge * PrimaryColor + (1 - vAlphaEdge) *
  SecondaryColor`, a darker line at the outside (`* 1 - 0.25 * ...`), the fill's alpha growing
  toward the edge, all from a distance field `BorderSDF` **[V]**. That PrimaryColor is the flag's
  slot 0 and SecondaryColor slot 1 is **[I]**.

### The territory

The game builds borders from a border-ID texture and an SDF texture (`border.shader` samplers
`BorderID`, `BorderSDF`), sized by `NGraphics.BORDER_TEXTURE_SIZE = 2048`, with
`BORDER_SYSTEM_RADIUS = 35`, `BORDER_HYPERLANE_THICKNESS = 20`,
`BORDER_INFLUENCE_MAX_DISTANCE_FACTOR = 1.88` and ownerless variants **[V]** (`00_defines.txt`).
How the engine fills those textures was not read. The renderer approximates it **[I]**: a point
belongs to the nearest owned system if within `BORDER_SYSTEM_RADIUS` (a Voronoi diagram of the
owned systems clipped to discs; unowned systems do not cut it); the signed distance to the edge is
the smaller of the distance to the disc's rim and to the bisector with the nearest system of
another owner; shaded like `PixelShaderSDF`. Hyperlane thickness and the influence factor are not
used.

### The art

| layer | file | how | mark |
|---|---|---|---|
| stars | `gfx/map/star_classes/%s.dds` (string in the exe) | 128x128 glows on black (A8R8G8B8, alpha 255; `black_hole.dds` DXT5): drawn added | path **[V]**; which name fills `%s` **[I]**: the renderer tries the star class key (`sc_m_giant.dds` exists) then the class (`g_star`); 24 classes in the 2210 save all resolve |
| star size | `NGraphics.GALAXY_STAR_ICON_SCALE = 1.5`, `GALAXY_STAR_ICON_MAX_SCALE = 1.25`, the class's `icon_scale` | renderer: 6 map units x scale x icon_scale, at least 12 px | defines **[V]**, size **[I]** |
| hyperlanes | `NGraphics.HYPERLANE_DEFAULT_COLOR = { 0.0 1.0 1.0 0.2 }` | read as RGBA (cyan, 20%); `HYPERLANE_NO_ACCESS_COLOR = { 0.9 0.15 0.0 0.4 }` is red-orange in RGB; the HSV defines are named `_HSV` | value **[V]**, RGBA **[I]** |
| dust | `gfx/map/dust.dds` (1024², DXT5, mostly transparent clouds) tinted by `gfx/map/galaxycolor.dds` (2048², DXT5: a spiral galaxy's colour field) | `galaxy_dust.shader`: `vUVColor = (vPos.xz + DustCloudUV.xy) / DustCloudUV.zw`, the colour map sampled at the dust's position **[V]**; renderer: one cloud per system plus half as many at random, size `GALAXY_DUST_SIZE (25) + rand * GALAXY_DUST_SIZE_EXTRA (35)`, added **[I]** |
| centre | `gfx/map/center.dds` (1024², DXT5) | `galaxy_center.shader` **[V]**; renderer: a quad of 0.55 x the galaxy's radius at 0,0, added **[I]** |
| not used | `gfx/map/sky_core/mid/rim/ycocg.dds` (2048² DXT5 cube maps, YCoCg-coded), `nebula.dds`, `nebulacolor.dds`, `edge.dds`, `hexgrid.dds`, `*_border_*.dds` | the sky (`sky.shader`, a cube map), nebulae, the fallen-empire and conflicted border fills **[V]** files, use **[I]** |

### The top bar of the main screen

`interface/main.gui`, window `maingui`, children `topbar` (background `GFX_topbar_background`, a
cornered tile), `topbar_extended`, `topbar_static` (the resource groups), `time_window` (the date,
speed controls), and the window `maingui_flag` **[V]**. Each group is a 70x36 container with
`GFX_topbar_button_narrow_hover` (2 frames) as background, an icon (`GFX_resource_energy` ...) at
26,2 and an `instantTextBoxType` "amount" at `@topbar_amount_pos_y = 17`, `cg_16b`, centred
**[V]**. Several groups share a position (consumer goods and biomass at x = 216, operational
reserves over energy): the game shows one or the other at run time **[V]** positions, which one
**[I]** (the renderer hides biomass and operational reserves when the stockpile lacks them).

Bound from the save **[V]** fields, formatting **[I]**: the stockpiles
`country.modules.standard_economy_module.resources` (`energy minerals food consumer_goods alloys
trade influence unity`, the research areas `physics_research` etc.), `empire_size`,
`standard_leader_module.leaders`, `starbase_capacity_used`/`starbase_capacity`,
`used_naval_capacity`, the date. The renderer shows whole numbers, "K" from 10,000 **[I]**; the
research group shows the sum of the research stockpiles, where the game shows the month's research
**[I]**.

## 2. The main menu and the load game window

### Files **[V]**

| what | file | names |
|---|---|---|
| the menu | `interface/frontend.gui` | windows `frontend_background` (button `animated_background`, `GFX_frontend_animated_bg`, 1280x720), `frontend_background_view` (the links: `privacy`, `pi_achievements`, `homepage`, `forum`, `facebook`, `twitter`, `you_tube`, `discord`), `frontendgui` (`main_menu_gradient`, `game_logo`, `menu/version`, `menu/buttons/*_container`, the logos, `additional_content_whats_new`, `portrait_room`, `blocker`) |
| its sprites | `interface/frontend.gfx` | `GFX_main_menu_button` (`button_main_menu.dds`, 3 frames), `GFX_faded_gradient_tile` (cornered, border 1,0), `gfx_game_logo`, the link icons, `GFX_frontend_animated_bg` (`transp_white.dds`, `buttonstate_rendertarget.shader`) |
| the buttons | `frontendgui/menu/buttons` | containers `start_game_container`, `load_game_container`, `multiplayer_container`, `coop_container`, `additional_content_container`, `settings_container`, `credits_container`, `quit_container`, each a `buttonType` (`id` start, load, multiplayer, coop, additional_content, settings, credits, quit) and an `instantTextBoxType` "text" (`jura`, `FRONT_START` ... `FRONT_QUIT`) |
| the in-game menu | `interface/mainmenu_view.gui` | `mainmenu_window` (save, load, settings, resign, quit, resume: `MAIN_RESUME`); not the front end |
| the load window | `interface/loadgame_view.gui` | `LoadGameScreen` (1270x710, centred: `load_label` `MAIN_LOAD` in `large_title_font`, `hide` = Cancel, `list` a `smoothListBoxType` 617x578, `selected_window` with the chosen session's details), the row template `LoadGameSessionEntry` (620x102: `select`, `name`, `date`, `save_name`, `load_latest`, `delete`, portrait, flag, icons) |
| the background | `common/frontend_backgrounds/00_frontend_backgrounds.txt` | `stellaris_base`, `apocalypse`, `federations`, `nemesis`, `overlord`, `firstcontact`, `machineage`, `biogenesis`, `nomads` (`default = yes`); the display name is `<tag>_FRONTEND_NAME`, plus `LATEST_RELEASE_FRONTEND_NAME` and `RANDOM_FRONTEND_NAME` (strings in the exe and keys in the localisation) |

The entity named by a background (`nomads_frontend_root_entity`) is in `gfx/models/ui/*.asset`; it
attaches entities whose `pdxmesh` (`nomads_frontend_mesh`) is in `gfx/models/ui/*.gfx`, with
`meshsettings` per shape: `background_geoShape` -> `nomads_frontend_export_background.dds`
(1920x1080), planets and ships -> `nomads_frontend_export_padding.dds`, and a flow mesh
(`PdxMeshFlowAlpha`, a flow map) **[V]**. The renderer draws the `background` shape's texture to
cover the screen as a still **[I]**: the 3D scene (planets, ships, the flow animation) is not drawn.

### Layout rules (`sim/render/lua/render/gui.lua`)

| rule | in the files | mark |
|---|---|---|
| rectangle | parent's content area + parent anchor (`orientation`: `UPPER_LEFT` default, `UPPER_RIGHT`, `LOWER_LEFT`, `LOWER_RIGHT`, `CENTER`, `CENTER_UP`, `CENTER_DOWN`, `CENTER_LEFT`, `CENTER_RIGHT`) + `position` - own anchor (`origo`) | **[I]** |
| keys | any case (`Orientation`, `orientation`; `spriteType`, `SpriteType`) | **[V]** both occur |
| sizes | `size = { width height }` or `{ x y }`; `100%`, `75%`, also written `100%%`: percent of the parent | **[V]** syntax, meaning **[I]** |
| margin | `margin = { top right bottom left }` insets the children (the logo's comment: "Makes the logo appear to have the same top and left margin as other elements") | **[V]** comment, rule **[I]** |
| scripted variables | `@name = value` at the file's top, in `guiTypes`, and inside windows (`@button_large_width = 340` is declared in `buttons` after `buttons` uses it in its own size): scoped to the window and its children, hoisted | **[V]** placement, scoping **[I]** |
| resolution variants | `if_scaled_resolution = { min_height = 900 position = ... size = ... }` overrides the fields it gives when the (scaled) screen matches; `min_height`, presumably also `max_height`, `min_width`, `max_width` | **[V]** syntax, semantics **[I]** (UI scale taken as 1) |
| sprite frames | `noOfFrames = n`: the texture is n frames side by side; `frame = k` counts from 1; a button's frames are normal, hover, pressed (disabled) | **[V]** syntax, order **[I]** (the 3-frame `button_main_menu.dds` shows a hover bar in frame 2) |
| cornered tiles | `corneredTileSpriteType` with `borderSize = { x y }`: nine slices, corners at their size | **[I]** |
| backgrounds | a window's `background = { spriteType or quadTextureSprite }`: a cornered tile fills the window, a plain sprite keeps its own size (the top bar's 8-px `GFX_vertical_divider` would otherwise be stretched to 150 px) | **[I]** |
| icons, buttons | the frame's size x `scale` when no `size`; `alwaysTransparent = yes` takes no clicks | **[I]** |
| texts | `instantTextBoxType` box `maxWidth` x `maxHeight`; `format = left/center/centre/right`; `vertical_alignment = center`; `text_color_code = "E"` gives the base colour; `font` default `cg_16b` | **[V]** keys, rendering **[I]** |
| button texts | `buttonText` (+ `buttonFont` or `font`) centred on the button | **[I]** |
| lists | `smoothListBoxType`, `listboxType`, `gridBoxType`, `overlappingElementsBoxType` are filled at run time from a template window; `dropDownBoxType`'s `expanded_window`/`expandedWindow` is closed | **[V]** names, filling **[I]** |
| what the game decides | `blocker` (the shade over the menu while a window is open), `pause_bg`/`pause_bg_stop`, which resource groups show, `selected_window` | **[I]** |

The menu at 1920x1080 lays out as the game's: buttons at x 50..390, y from 253 every 75 px (the
`min_height = 900` variant), the logo at -3,17 **[V]** (rendered and read back).

### The textures

DDS in the game, decoded on the CPU (`image_dds` 0.7.2 with `ddsfile`), mip chains built on the CPU
**[V]**:

| format | files in `gfx/` + `interface/` |
|---|---|
| A8R8G8B8 (raw 32-bit, masks 00ff0000/0000ff00/000000ff/ff000000) | 13,319 |
| DXT5 (BC3) | 6,574 (6 cube maps) |
| DXT1 (BC1) | 645 (4 cube maps) |
| R8G8B8 (raw 24-bit) | 626 |
| DXT3 (BC2) | 153 |
| A1R5G5B5 | 15 |
| A8B8G8R8 | 8 |
| not DDS (a UTF-8 BOM: `gfx/interface/icons/traits/all_negative.dds`, `gfx/interface/main/paused_bar_glow.dds`) | 2 |

Font pages and one menu font's page are `.tga` (uncompressed type 2, 32-bit, top-down) **[V]**.
Paths in the files are written for Windows: looked up ignoring case **[I]**.

## 3. Localisation (`sim/lua/engine/localisation.lua`)

- **Files** **[V]**: `localisation/<language>/**/*_l_<language>.yml`; `english` has the
  subfolders `name_lists` and `random_names`, 232 files, 150,206 keys (0.6 s in LuaJIT). The
  first line, after a UTF-8 BOM, is `l_english:`; then ` KEY:0 "text"` per line (the number is a
  version and may be absent), `#` comments.
- **Languages** **[V]**: `localisation/languages.yml` lists them (`l_english`, `l_braz_por`,
  `l_german`, `l_french`, `l_spanish`, `l_polish`, `l_russian`, `l_simp_chinese`, `l_japanese`,
  `l_korean`) with several `l_<lang>:` headers in one file; the strings `localisation/`,
  `localisation/languages.yml` and `l_english` are in the exe. The game presumably reads each
  file's blocks by their header **[I]**; the loader reads one language's folder, so
  `languages.yml` (at the root, several headers) is not read.
- **Order** **[I]**: files sorted, a `replace/` folder's last, a later key replacing an earlier one
  (Paradox's convention; 4.5.2's English has no `replace` folder).
- **The text** **[V]**: from the first `"` to the last one on the line (texts contain unescaped
  quotes); `\n` is a new line, `\"` a quote.
- **References** **[V]**: `$KEY$` is another key's text (`nomads_FRONTEND_NAME: "$NOMADS_TITLE$"`);
  `$KEY|format$` carries a format (`$VALUE|0$`, `$@living_standard_energy_normal|*0$`). `get`
  resolves keys to a depth of 8 and leaves what is not a key (`$VALUE$`, `$ICON$`: filled by the
  game at run time) **[I]**; the format part is dropped **[I]**.
- **Colour codes** **[V]**: `§X` opens a colour, `§!` closes the innermost (`MULT_POS: "§Gx$VALUE$§!"`);
  the letters are `interface/fonts.gfx`'s global `textcolors` (G green, R red, Y yellow, H
  highlight, E event green, T text, W white, g grey, `_` placeholder magenta, digits and lower
  case for rarities...). `spans(text)` splits a text into `{ text, colour }` parts for the
  renderer.
- **Icons** **[V]**: `£pop£`, `£$ICON$£`; `spans` gives `{ icon = name }`; the renderer does not
  draw them yet.
- **Commands** **[V]**: `[This.GetName]`, `[GetYear]`: evaluated by the game; kept as text.
- A missing key shows as the key itself **[I]** (as the game does in debug).

## 4. Fonts

- **Declared** in `interface/fonts.gfx` **[V]**: `bitmapfonts = { textcolors = { ... } bitmapfont
  = { name fontfiles = { "gfx/fonts/cg_16b" } color = 0xffffffff ... } }`; some use `path =
  "gfx/fonts/orbitron"` instead of `fontfiles` (`large_title_font`); `bitmapfont_override` gives
  TrueType fonts (`ttf_font`, `ttf_size`) for `l_russian`, `l_polish`, `l_simp_chinese`,
  `l_japanese`, `l_korean`. `color` is 0xAARRGGBB (the file's comment). `textcolors` is global for
  all fonts.
- **Format** **[V]**: AngelCode BMFont text: `info face=... padding=3,3,3,3`, `common lineHeight
  base scaleW scaleH pages`, `page id=0 file=...`, `char id x y width height xoffset yoffset
  xadvance page`, `kerning first second amount`. The page the `.fnt` names may not exist
  (`juralightmedium_0.dds`; `orbitron.tga`, `cg_34.tga`): the texture is `<file>.dds` beside the
  `.fnt`, or the `.tga` **[V]** files, lookup order **[I]**.
- **Used** **[V]**: `cg_16b` (Century Gothic bold 16: the top bar, the version, dates; 228 glyphs,
  no kerning, digits all advance 7), `jura` (`juralightmedium`: the menu's buttons; line height 48,
  6,745 kerning pairs), `large_title_font` (`orbitron`, `.tga` page; line 36), `malgun_goth_24`
  (the load window). The pages carry the glyphs in RGB as well as alpha (grey with a dark edge),
  multiplied by the text's colour **[V]** pixels, use **[I]**.
- Glyph cells overlap by the padding (`xoffset = -3`); reading a text back from pixels needs the
  font's kerning, the glyphs' full cells (descenders: orbitron's `q`) and whole-line matching
  (`sim/render/src/verify.rs`) **[V]** measured.

## 5. GPU backends

- **wgpu 30.0.1** with winit 0.30.13. On 10.5.0.24: Vulkan; NVK (Mesa 26.0.8) on the GTX 1080 Ti
  (GP102, Pascal, 11 GB; before 2026-10-15 a GT 730, GK208B Kepler, which rendered the same: the
  default system view's mean colour is 9.3, 14.8, 30.4 on both)
  renders correctly offscreen; under Xvfb it cannot present (no DRI3), so a window
  there runs on llvmpipe (lavapipe) **[V]**. The two Vulkan devices agree to 2/255 per channel on
  the plain map and 7/255 on the art map (filtering) **[V]**.
- **The laptop**: Radeon RX Vega M GL (driver 24.20.11001.8003) and Intel HD 630. Vulkan:
  `amdvlk64.dll` 9.2.10.20 (2018) crashes on the first frames after "surface: Bgra8UnormSrgb
  1280x1024, Immediate" (exceptions c0000005, c000041d at offset 0xd1b0), and its hyperlane
  pipeline draws nothing even offscreen (the lane layer changes 0 pixels) while everything else
  draws; Intel's Vulkan driver exits with code 5 at start **[V]** (measured; the cause in the
  driver not known). DX12 on the same Radeon draws everything, lanes included, offscreen and in a
  window **[V]**.
- **The choice**: DX12 is compiled in and the default on Windows, Vulkan elsewhere, `--backend
  vulkan|dx12` to override; on AMD's Windows Vulkan driver the lane check only warns.
- **DX12 notes** **[V]**: the shader compiler is wgpu's `Dx12Compiler::Auto` (DXC if present, else
  FXC); adapters seen: the Intel, the Radeon and "Microsoft Basic Render Driver" (CPU); the surface
  offers `Bgra8Unorm` besides `Bgra8UnormSrgb`; present mode `Mailbox`.
- **Colour space**: the textures are uploaded as `Rgba8Unorm` and blended in gamma space, like the
  game's DX9-era UI; the offscreen target is `Rgba8Unorm`; the window picks a non-sRGB surface
  format when there is one, so the window matches the checked PNGs (through an sRGB surface the
  20% cyan lanes came out much brighter) **[V]** measured. With an sRGB target the shader converts
  sRGB to linear.
- **Limits**: the adapter's own (`adapter.limits()`, no downlevel cap any more; the renderer
  needs 2048, for the colour maps and border texture). `write_texture` needs no row alignment;
  `copy_texture_to_buffer` needs rows of 256 bytes.
- **Windows**: a window that does not fit the screen runs below it; without `--size` the window is
  fitted to 85% x 80% of the monitor.

## 6. How the renderer checks itself

The PNG is read back from disk and compared with renders that leave one layer out (background,
borders, lanes, stars, GUI, text): every star sprite changes pixels in its rectangle (596/596),
every lane at its middle (853/853), each owner's fill matches the border texture's colour over the
frame without borders (mean error 0.4/255), every GUI sprite with visible texels changes pixels,
every text is read back from the pixels with its font's glyphs and compared with the save's value
or the localised text. In the window, real input was driven under Xvfb with xdotool (hover, press,
click Load Game, a save, Escape, Exit), and on the laptop the window was captured with
`PrintWindow` and `CopyFromScreen`.

For the 3D work: `--mesh-census DIR...` reads every mesh and checks every index and skin
reference; `--mesh-info FILE...` prints a mesh's shapes, materials, skins, locators, and the share
of outward normals and counter-clockwise triangles; `--model-census` resolves every entity to its
mesh and textures (section 7); the scripted example of section 9 renders the galaxy from three
angles, a system and the models, with frame times. The 3D views are compared with the real game's
frames of the same commands (`headless/view.sh`, section 10), by eye and by the places of known
objects on the screen (no pixel-difference check yet).

## 7. Meshes and entities (`gfx/models`)

### The binary mesh format **[V]**

Read in `sim/render/src/pdxmesh.rs`. All 2,968 `.mesh` files of `gfx/models` (portraits
included) read without an error in 2.0 s: 9,877 sub-meshes, 15,058,743 vertices, 16,466,552
triangles; every index is below its sub-mesh's vertex count and every skin's bone index below its
skeleton's size (`--mesh-census /opt/stellaris/gfx/models`). The format is a tree of objects with
typed properties, little-endian:

- **header**: the 4 bytes `@@b@`;
- **an object**: `[` repeated *depth* times (1 for the top level), its name, a NUL. It holds the
  properties and objects that follow, until an object of the same or a lower depth;
- **a property** of the last object: `!`, the name's length (1 byte), the name (no NUL), the type
  (`i` int32, `f` float32, `s` strings), a u32 count, the values (a string: a u32 length, then
  its bytes with the NUL).

The start of `gfx/models/planets/base_star.mesh`:

| offset | bytes | meaning |
|---|---|---|
| 0x00 | `40 40 62 40` | `@@b@` |
| 0x04 | `21 08` `pdxasset` `69` `02 00 00 00` `01 00 00 00` `00 00 00 00` | `!pdxasset`, `i`, 2 values: 1, 0 (the version) |
| 0x1B | `5b` `object` `00` | `[object` |
| 0x23 | `5b 5b` `atmosphere_geosphereShape` `00` | `[[` a shape |
| 0x3F | `5b 5b 5b` `mesh` `00` | `[[[mesh` a sub-mesh |
| 0x47 | `21 01` `p` `66` `08 0a 00 00` | `!p`, `f`, 2,568 floats (856 vertices x 3), from 0x4F |

The tree, with the number of files and occurrences in 4.5.2:

| path | type | what | files / occurrences |
|---|---|---|---|
| `!pdxasset` | i[2] | version, always 1, 0 | 2968 |
| `[object` / `[[<shape>` | | the shapes, Maya's shape names (`planet_geosphereShape`) | 2927 / 9555 |
| `[[<shape>!lod` | i[1] | the shape's level of detail | 5 / 16 |
| `[object!loddist` | f[3..4] | the LOD switch distances **[I]** | 5 |
| `[[[mesh` | | a sub-mesh of the shape | 2667 / 9877 |
| `mesh!p`, `!n` | f, 3 per vertex | positions, normals | 9877, 8510 |
| `mesh!ta` | f, 4 per vertex | tangent xyz and the bitangent's sign | 8508 |
| `mesh!u0`, `!u1` | f, 2 per vertex | uv sets (0 sets: 1369 sub-meshes, 1: 8429, 2: 79) | 8508, 79 |
| `mesh!tri` | i, 3 per triangle | indices | 9877 |
| `mesh!boundingsphere` | f[4] | centre and radius **[I]** | 1070 |
| `mesh!sfs` | f | not known | 1707 |
| `[[[[aabb` `!min` `!max` | f[3] | the sub-mesh's bounds | 9877 |
| `[[[[material` | | `!shader`, `!diff`, `!n`, `!spec` (s): the shader and the texture names | 9877 |
| `[[[[skin` | | `!bones` i[1] (influences used, at most 4), `!ix` i and `!w` f (4 per vertex) | 5729 |
| `[[[skeleton` / `[[[[<bone>` | | `!ix` i, `!pa` i (the parent, absent for a root), `!tx` f[12] (3x4) | 1012 / 171,974 |
| `[locator` / `[[<name>` | | `!p` f[3], `!q` f[4], `!pa` s (a parent bone), `!tx` f[16] (newer exporter) | 2024 / 17,333 |

- **Quaternions are x, y, z, w** **[V]**: the explosion locators of
  `mammalian_01_science.mesh` all carry `0 0 -0 -1`, the identity in that order.
- **Normals point out and triangles wind counter-clockwise seen from outside** **[V]**: 100% of
  the vertices and triangles of the spheres of `planet_clouded.mesh` and `base_star.mesh`
  (`--mesh-info` reports both for every sub-mesh).
- **Ships face -z** **[V]**: the engine and exhaust locators of the science ship are at z = +2.2 to
  +2.6, the hull spans z = -3.2 to +2.9.
- **What the renderer covers**: positions, normals, tangents, uv set 0, indices, materials,
  locators (for attachments). **Skinning** is read (bones per vertex, indices, weights, the
  skeleton) but meshes are drawn in their bind pose: the animations (`.anim`) are not read.
  **LODs**: the 16 LOD shapes (5 files) are read but not chosen between; all shapes are drawn.
  `u1`, `boundingsphere`, `sfs` and the locators' `tx` are read and unused.

### Entities and pdxmeshes **[V]**

`sim/render/lua/render/models.lua` indexes the definitions in place: 7,953 entities and 2,821
pdxmeshes in 531 files (257 `.gfx`, 274 `.asset`, `gfx/models/portraits` left out) in 0.7 s.

- **a pdxmesh** (`.gfx`): `objectTypes = { pdxmesh = { name file scale meshsettings = { name index
  texture_diffuse texture_normal texture_specular shader } animation = { id type } } }`. The
  `meshsettings` `name` is the shape it applies to; it may be a Maya path (`a|g_body|g_bodyShape`:
  the last part is the shape) or absent (all shapes) **[I]**. `index` is not used **[I]**. A
  repeated key counts with its last value **[I]** (`mammalian_01_science_mesh` says `scale = 1.0`,
  then `scale = 2.8`: 2.8 is used).
- **Collision shapes** (material shader `Collision`, 3,396 shapes) are never drawn, whatever a
  meshsettings says: `mammalian_01_science_mesh`'s nameless `meshsettings = { shader =
  "PdxMeshShip" }` gave its collision box (`pCubeShape1`) the ship shader, and that box was the grey
  slab behind the science ship in the first model renders (fixed).
- **an entity** (`.asset`): `entity = { name pdxmesh scale meshsettings attach = { <locator> =
  "<entity>" } state = { ... } locator = { name position rotation } clone = "<entity>" }`. 1,036
  entities attach others; `clone` copies another entity (its mesh and settings, its own settings
  over them **[I]**).
- **the census** (`--model-census`): 6,347 entities load as a model; 1,606 have no pdxmesh (locator
  dummies such as `crystal_ship_small_section_entity`, weapon and hit effects); 1,822 of the loaded
  have no part to draw (frames made of locators, effects). The shaders of the drawn parts:
  PdxMeshShip 4282, PdxMeshShipDiffuseEmissive 682, PdxMeshTerra 324, PdxMeshClouds 283,
  PdxMeshAtmosphere 123, PdxMeshPlanet 84, PdxMeshStar 15, PdxMeshAtmosphereStar 16, others; not
  drawn: Collision 3,396 shapes, the additive, flow and alpha-blended effect shaders.
- **Texture names** are file names. They are found **[I]**, in order: beside the file that
  defined the entity, beside the pdxmesh's file, beside the mesh, then anywhere in `gfx/models`
  by name (`nonormal.dds` and `nospec.dds` are in `gfx/models/`; the starbases' meshes in
  `ships/starbases/` name their culture's textures in `ships/<culture>/`); a `.tga` name is read
  as the `.dds` (11 ship textures name a `.tga`; only the `.dds` ships). Of 18,596 texture names of
  drawn parts 18,593 are found (the 3 others: `toxoid_01_starbase_modules_*`, missing in 4.5.2).

### Which entity draws what **[V]** (the chain), **[I]** (the details)

- **A planet or a star**: its class (`common/planet_classes`) has `entity` (`desert_planet`,
  `g_star_class_star_entity`), `entity_scale` (`@planet_standard_scale` = 11; stars 20),
  `atmosphere_color`, `atmosphere_intensity`, `atmosphere_width`. A planet's `entity` field in the
  save picks the variant: `desert_planet_0<N+1>_entity` **[I]** (else `_01_entity`). Planets are
  `planet_clouded.mesh` (shapes `planet_geosphereShape` PdxMeshPlanet, `clouds_geosphereShape`
  and `clouds_shadow_geosphereShape` and `polesShape` PdxMeshClouds, `atmosphere_geosphereShape`
  PdxMeshAtmosphere, `pCubeShape1` Collision; 1 bone per vertex on the skeleton `root
  planet_rotation planet clouds end`); stars `base_star.mesh` (PdxMeshStar, PdxMeshAtmosphereStar).
  **The size** **[V]** (CPlanet::CalcCurrentEntityScale, and the game's own values for system
  401's bodies): `planet_size` x 0.1 x the class's `entity_scale` x NGraphics.PLANET_SCALE_SYSTEM
  at the zoom (interpolated over the zoom steps; 0.35 when `g_bDisableScaling` is set, which it
  is in 4.5.2 by default: 0.35 at every distance) x MOON_SCALE (0.7) for a moon; the entity's own
  `scale` on top (in system 401: 1.6 for the A star's, 1.2 for the gas giant's, 0.5 for the brown
  dwarf's).
  E.g. the A star of size 34: 34 x 0.1 x 20 x 0.35 = 23.8, x 1.6 in its world transform.
- **A ship**: `ship_design_implementation.design` -> the design's first `growth_stages` -> its
  `ship_size` and `section`s (`template`, `slot`). The frame is `<graphical_culture>_<size>_entity`
  (`molluscoid_01_corvette_entity`, a mesh of locators); each section's template
  (`common/section_templates`: `ship_section_template = { key entity }`) gives an entity, prefixed
  with the culture (`molluscoid_01_corvette_S3_entity`), placed at the locator that
  `common/ship_sizes`' `section_slots = { "<slot>" = { locator = "part1" } }` names for the slot.
  Starbases, mining and research stations are ships of the same form (`starbase_starport`,
  `mining_station`). In system 401 of the 2210.01.01 save all 11 ships resolve to models.

## 8. The mesh shaders, matched (`gfx/FX`)

`sim/render/src/mesh.wgsl` ports the parts of the game's pixel shaders that make the look; the
game's code was read in `gfx/FX/pdxmesh.shader`, `standardfuncsgfx.fxh`, `standard_vertex.fxh`,
`pdxmesh_samplers.fxh` and `gfx/worldgfx/*.txt` **[V]** (the formulas), with the renderer's own
simplifications **[I]** (named).

- **The normal map** (`UnpackRRxGNormal`, standardfuncsgfx.fxh:542) **[V]**: x = green x 2 - 1,
  y = -(alpha x 2 - 1), z = sqrt(1 - x² - y²); the tangent frame rows tangent, bitangent, normal,
  the bitangent `cross(normal, tangent) x tangent.w` (standard_vertex.fxh:27). The maps agree:
  `desert_01_normal.dds` has red ≈ green ≈ 128, blue 0, alpha ≈ 127 on average.
- **The specular map** (PixelPdxMeshStandard, pdxmesh.shader:526) **[V]**: green the specular
  (`g² x 0.4`), blue the metalness (`1 - (1 - b)²`; the diffuse x (1 - metalness), the specular
  colour mixed toward the diffuse by it), alpha the glossiness, red the empire colour / city
  lights mask. **The normal map's blue is the emissive** (`EMISSIVE`: PdxMeshTerra,
  PdxMeshPlanet): `colour = mix(lit, diffuse, emissive)` (a ship's windows); on planets only on
  the night side with city lights, not drawn here, except where `NO_PLANET_EMISSIVE` is defined
  (PdxMeshPlanetEmissive, PdxMeshMoltenPlanet and their skinned forms): there everywhere (the
  molten planets' lava).
- **The planets' lights** (CalculateSystemPointLight with IS_PLANET) **[V]**: the star's point
  light, the world's `system_light` of `gfx/lights` (A stars: `a_class_star`, white x 2.5), plus
  `system_back_light_diffuse` (A stars: hsv 0.58 0.25 0.55) on the side away from the star
  (`CalculateLight(N, L, colour)` takes `dot(N, -L)`).
- **Colour constants are linear** **[V]** (4.5.2 Linux code): with `g_bUsesRGB` (the default;
  `-nosRGB` and `-nohdr` clear it) `GfxToLinear` raises a colour to 2.2. It is applied to the
  worldgfx lava colours (CWorldGraphicalMapData::ReadMember, before the `_intensity`), the planet
  class's atmosphere colour (SetStarEntityCustomData, SetPlanetEntityCustomData), the system
  light's colour (CGameRendering::SetSystemLight, then x its intensity), and twice to the light
  settings (`system_back_light_diffuse`, `cam_light_*`, `ambient`, `rim_light_diffuse`:
  SLightDescription::ReadMember and again in SetConstants, so ^4.84). Particle colours go through
  `ToLinear` in particle.shader. Textures loaded with `AddTexture_sRGB` (the colour maps, the
  star's noise, lava and stone) are read linear.
- **Winding and culling** **[V]**: the game's meshes are front-facing clockwise under its
  left-handed view (D3D); the renderer culls back faces with that winding (and the atmospheres'
  front faces), as the frames of both agree.
- **The planets' atmosphere tint** (IS_PLANET) **[V]**: `toCamera = saturate(dot(N, -V) + width)`,
  `toSun = dot(N, L) x 0.5 + 0.5`, `a = lerp(toCamera, toCamera x toSun, 0.5)`, the colour mixed
  toward `atmosphere_color` by `a² x AtmosphereColor.a x intensity`: on planets nothing, as the
  game sets AtmosphereColor.a to 0 (section 11).
- **Clouds** (PdxMeshClouds: the standard shader with IS_CLOUDS) **[V]**: clipped where
  `dot(N, V) < 0.27`, blended by the diffuse alpha.
- **The atmosphere shell** (PixelPdxMeshAtmosphere, `RasterizerStateBack`, additive) **[V]**: the
  colour x 0.15 plus the colour x (the star's light and back light, the specular of glossiness 1)
  x 0.13 x 2, times `(dot(N, -V) x 1.2)⁴`. With
  outward normals only back faces give a non-zero `dot(N, -V)`: the shell is drawn on its back
  faces (front faces culled), brightest behind the planet, a halo around it.
- **The star** (PixelPdxMeshStar) **[V]**: lava and stone textures over a noise, the colours from
  the star class's `gfx/worldgfx/star_<x>_class.txt` (`lava_bright_color`,
  `lava_hot_stone_color`, `lava_cold_stone_color`, each x its `_intensity`; `tex_lava_diffuse` =
  `gfx/worldgfx/lava_d.dds`, `tex_stone_diffuse` = `stone_d.dds`, `tex_lava_noise` a cube map),
  then the class's atmosphere colour toward the limb, a rim x 3.5, x 2, alpha 0. The class
  `pc_g_star` uses the world `g_star` **[I]**. The game samples the noise cube
  (`gfx/worldgfx/lava_noise.dds`, 1024² DXT1, sRGB) at the direction, x 4 and x 8: the same
  direction, so the same texel three times **[V]** (the code); the renderer does the same, at time
  0. The textures' slots **[V]** (ReadMember's member table): noise, lava (`lava_d.dds`), stone
  (`stone_d.dds`).
- **The star's glow** (PixelPdxMeshAtmosphereStar, BlendStateAdditiveBlend) **[V]**: the colour x
  `dot(N, -V)³`, alpha `dot(N, -V)⁴`, on the back faces; the blend writes alpha (see the bloom's
  mask, section 11).
- **Additive blending and alpha** **[V]**: the game's blend states without `SourceAlpha` /
  `DestAlpha` keep the default alpha factors (ONE, ZERO, ADD), which makes the OpenGL backend call
  `glBlendFunc` (SOpenGLBlendState::Init, GfxSetBlendStateOpenGL): alpha is blended by the colour
  factors. So `BlendStateAdditiveBlend` and the particles' `BlendStateAdditive` (SRC_ALPHA, ONE,
  RGBA written) add alpha² to the scene's alpha, the bloom's emissive mask; `...NoAlpha` and the
  alpha-blended states write RGB only. The planet atmosphere (`BlendStateAdditiveBlendNoAlpha`)
  returns alpha `1 + 2.9 dot(N, -V)`: SRC_ALPHA scales its colour by that (unclamped on the float
  target).
- **Ships** (PixelPdxMeshShip), **the environment map**, **gas giants and molten planets** (the
  flow map), **rings**, **asteroids**, **additive effects**: section 11.
- **Not drawn**: shadows, the tiled point lights, the lens flare, city lights, the dissolve and
  cloak effects, animation (planets' spin, ships' skeletons). The post effects, the sky and the
  particles: section 11.

## 9. The command protocol (headless, TCP)

`stellar-render --listen [ADDR:]PORT` (or `STELLAR_RENDER_LISTEN`; a port alone listens on
127.0.0.1) serves one client at a time; `--script FILE` runs the same commands from a file. One
command per line, one reply per command, sent when the command is complete (a frame is rendered
and written before its reply), so a client scripts exact sequences. Replies: `ok ...` or `error
...`. `sim/render/src/engine.rs`. **The real game speaks it too**: `headless/view.sh` (section 10)
runs the Linux 4.5.2 build with its frames drawn and serves the same commands (`load`, `pause`,
`step`, `view`, `focus`, `camera`, `resize`, `gui`, `frame`, `state`, `quit`), so one command file
takes the same shots of both.

| command | reply / effect |
|---|---|
| `load PATH`, `load-sim PATH` | the save's world (fast), or with the simulation loaded on its thread too (waited for); either way the home system is shown, as the game does after a load (section 12) |
| `step DAYS` | runs the simulation DAYS days and waits for them (its thread is started and loaded first if needed) |
| `pause`, `pause off` | the game's clock stopped (as the game's headless `pause`), or running in real time at its speed (section 12) |
| `speed 1..5` | the clock's speed (Slowest .. Fastest) |
| `wait SECONDS` | real time passes (the clock runs meanwhile); replies with the date |
| `select system\|fleet\|planet\|ship ID`, `select none` | the selection, as a click makes it: its marker, the outliner's row, its window |
| `view galaxy` / `3d` / `2d` / `system ID` / `model NAME` / `menu` | what the map screen shows (from a system, `view galaxy` leaves it as the game does: at its star, ZOOM_STEPS_GALAXY[1]) |
| `focus system ID`, `focus fleet ID` | the galaxy camera over it |
| `camera X Y Z YAW PITCH DISTANCE` | the game's camera (section 10): its target (map x = X, map y = Z), angles in degrees, the distance in map units |
| `orbit DYAW DPITCH`, `zoom FACTOR`, `pan DX DY` | relative moves (pan in fractions of the distance) |
| `resize W H`, `key NAME down\|up`, `mouse X Y [left\|right down\|up]`, `scroll DY` | input (`scroll`: the wheel, a zoom step a notch about the point under the mouse) |
| `gui off\|on` | the GUI (the top bar, the outliner, a system's orbit lines) hidden or shown |
| `observe` | the game's console `observe` (headless.c calls OnExecute_Observe: the local human gets no country): the whole galaxy known, every country's borders, flags and names, every system's label, no sectors; the renderer's from then on, after each simulated day too (the top bar and outliner stay the player's here; the game's observer has none) |
| `frame PATH.png` | `ok frame PATH W H MS` (MS: scene, upload, GPU and read-back) |
| `frame -` | `ok frame - W H MS BYTES`, then the PNG's bytes |
| `state` | JSON: screen, view, camera, date, the clock (paused, speed, loading, days run, a day's and a snapshot's ms), the selection, systems, fleets by movement state, FTL trails, size |
| `bench SECONDS [FPS]` | frames at FPS (120) drawn as a window draws them, on the commands' one thread: what they took against the frame's time (section 12; `--bench SECONDS` measures the window's own way, the app on its UI thread) |
| `quit` | ends the server |

The game's headless serves `pause` and `step` the same way; `speed`, `wait` and `select` are the
renderer's only (headless/ is not changed).

The client `sim/render/tools/ctl.py` (standard library only) sends commands, files of commands, or
`--get OUT.png`; `ctl.py example SAVE OUT_DIR [SYSTEM]` loads the save, takes three galaxy shots
from different angles, focuses a home system, takes a system shot, and lists the PNGs with their
frame times. Run on 10.5.0.24 with the 2210.01.01 save:

```
stellar-render --game /opt/stellaris --listen 7878 &
python3 sim/render/tools/ctl.py example /opt/stellaris-saves/autosave_2210.01.01.sav OUT 401
  OUT/example_galaxy_1.png  1600x900  295 ms   (first frame: the map's textures load)
  OUT/example_galaxy_2.png  1600x900  48 ms
  OUT/example_galaxy_3.png  1600x900  95 ms
  OUT/example_focus.png     1600x900  113 ms
  OUT/example_system.png    1600x900  2743 ms  (first system frame: ~40 textures load)
```

## 10. The 3D views, checked against the game

### Reference shots from the real game (`headless/view.sh`)

`headless/view.sh [--size WxH] [--listen PORT] [--script FILE] SAVE` on 10.5.0.24 runs the Linux
4.5.2 build under Xvfb with its frames drawn (Mesa llvmpipe: 10 to 20 ms a frame at 1600x900),
loads the save and serves the protocol (`headless/README.md`, view mode). Its `camera` sets the
game camera's orientation every frame after the game's own update; its `frame` waits for the
picture to settle (2 s, then two captures in a row nearly equal) and captures the window from the
X server; its `state` returns the game's camera as the game keeps it (orientation, eye, look-at,
FOV, near, far, the view and projection matrices) and, for `state planet ID`, the body's entity
scale and world transform. The comparisons below are the same command files run on both
(`H:\code_working\tmp_sym\render3d\reference\compare_*.png`: the game, the renderer at 170064e,
the renderer now).

### The camera **[V]**

The game's (CGameCamera, read from the code; its `state` and its frames agree):

- **The orientation** (CGameCamera +0x218: target x y z, distance, pitch, yaw; a target
  orientation at +0x230 that the current one is smoothed toward): the eye is target + distance x
  (-cos pitch sin yaw, sin pitch, cos pitch cos yaw) (UpdateInternalCamera, SetCameraPosition).
- **The view** is left-handed (MatrixLookAtLH: z from the eye to the target, x = up x z); **the
  projection** a left-handed perspective, depth 0..1, w = the view's z, a vertical field of view
  of NCamera.FOV = 35 degrees (CCamera::UpdateMatrices). At yaw 0 the eye is on the +z side:
  screen right is world -x and screen top world -z.
- **The world**: the galaxy is the map x GALAXY_SPACE_SCALE_MULT = 2, a system the map x
  SYSTEM_SPACE_SCALE_MULT = 10 (CCelestialCoordinate::GetDisplayCoordinate: a coordinate's fixed
  point x 1e-5 x the multiplier; z = the save's y). The renderer works in map units: the same
  picture, every distance / 2 or / 10.
- **Limits and defaults**: galaxy pitch 30..85 (57.5 after a load, distance 200 of the game's
  world; ZOOM_STEPS_GALAXY 100..3000); system pitch 20..80 (50 on entering; its zoom steps are
  ZOOM_STEPS_SYSTEM_PERCENTAGES x the system's size: 92.5 .. 11,100 for system 401); near 1 and
  far 5000 on the galaxy.
- **The renderer** (`sim/render/src/camera.rs`) now uses that camera; the 2D map follows the same
  orientation (x to the left, y downwards). The window's controls are the game's (section 12).

### The system view

Built from the world on every frame (`sim/render/lua/render/system.lua`, `src/system.rs`), so it
follows the simulation. The data **[V]**: the system's `planet` list (stars are planets whose
class says `star = yes`), each planet's `coordinate`, `planet_size`, `moon_of`, `entity`, class;
the fleets whose `movement_manager.coordinate.origin` is the system and their ships'
`coordinate` and `forward_x`/`forward_y`. From the game's frames and its `state`:

- **Bodies** at the save's coordinate x 10, at y = -150 of the game's world **[V]** (every body of
  system 401: their world transforms), each scaled as CPlanet::CalcCurrentEntityScale (section 7)
  **[V]**: the places and sizes of the stars, the brown dwarf and the molten planets match the
  game's frames within a pixel or two at 1600x900.
- **Ships** at y = 0, above the bodies' plane **[V]** (the starbase's place on the screen), at
  their model's size in the game's world **[I]** (fitted: the starbase's size within a few percent),
  turned to `atan2(-forward_x, -forward_y)` about y with the model's -z forward: the starbase's
  place and facing match the game's frames **[V]**.
- **Light**: a point light at the first star; orbit rings with the GUI.

### The galaxy in 3D

Drawn as the game draws it (stars, dust, nebulae, the core, terra incognita, borders, hyperlanes,
star pins, the post effects): section 11, "The galaxy view". With the GUI on, fleets are discs in
their owner's colour **[V]** (the owner: section 1); a fleet in an FTL state
(`movement_manager.state` `move_wind_up`, `move_galaxy`, `move_jump_anim`, `move_wind_down`; the
saves hold the first, the simulation all four) whose `path` leads to another system draws a trail
to that system **[I]**. The stars' places match the game's frames.

### What matches and what does not (the reference shots of 2210.01.01)

| | matches | does not |
|---|---|---|
| camera | field of view, orientation, handedness, distances: the stars and bodies at the same pixels | |
| system | the bodies' places and sizes; the starbase's place, size and facing; the sky box, the exposure, the bloom and the colour grading (mean colour of the default view within 1/255 of the game's); the star's corona, flares and glow; the molten planets, gas giants, rings, atmospheres, asteroid belts; the ships' empire colours, turrets and engine glows | the star's lava patches (a little purple where the game's are blue); the planets' spin and the ships' idle animations (section 11) |
| galaxy | the stars' places and icon size; terra incognita; the player's border ring; the dust, the nebulae, the hyperlanes and star pins; the post effects and sky; the core's glow; the empire and sector names and the flags | the hyperlanes and star colours from far, the nebulae's strength (section 11) |

### Frame times

The time of `frame` (scene, upload, the GPU's frame and the read-back; not the PNG's encoding):

| machine | galaxy 1600x900 | system 1600x900 | planet 1024² | ship 1024² |
|---|---|---|---|---|
| 10.5.0.24, GTX 1080 Ti (NVK, Vulkan; nouveau has no reclocking on Pascal: boot clocks) | 1.0 s first, 30 ms | 2.8 s first, 15 ms | 0.7 s first, 11 ms | 11 to 24 ms |
| 10.5.0.24, GT 730 (NVK, Vulkan; before 2026-10-15) | 295 ms first, 48 to 113 ms | 2.5 s first, 40 to 50 ms | 0.65 s first, 37 ms (star) | 24 to 70 ms |
| laptop, Radeon RX Vega M GL (DX12) | 500 ms first, 10 to 15 ms | 4.8 to 6.5 s first, 7 to 8 ms | 1.3 s first | 24 to 140 ms |
| the game under Xvfb (llvmpipe) | 10 to 20 ms a frame; a `frame` takes 2 to 2.3 s (the settling wait) | same | | |

The first frames are the textures' loading and decoding on the CPU (the planets' 2048x1024 maps,
the ships' sets). The simulation behind it: `load-sim` 7.7 s, a day 0.35 to 0.6 s. The game:
22 s from start to the loaded save, `step` about 30 ms a day.

## 11. Visual parity with the game (3D)

Each item is checked with one side-by-side at the game's default camera (system: pitch 50,
distance 11,100 of the game's world; galaxy after a load: pitch 57.5, distance 200), the game's
frame from `headless/view.sh` with the GUI off, the renderer's from the same command file
(`H:\code_working\tmp_sym\render3d\parity\N_*.png`, the game left).

| | item | state | what is missing |
|---|---|---|---|
| 1 | post effects: bloom, exposure, tone map, colour grading | done | the lens flare (ghosts and halo x `gfx/lensdirt.dds`); the exposure's adaptation over time (a still frame is adapted) |
| 2 | system backdrop: the sky box | done | (the galaxy view uses the `default` world's sky and post effects: item 5) |
| 3 | stars: surface, glow, corona particles, the star's light on planets | done for the A star of system 401 | the lava patches a little purple (cause not found); the particles' motion (a still snapshot); the other star classes, black holes, neutron stars and pulsars are not checked |
| 4 | planets: atmospheres, gas giants, rings, asteroid belts, black holes, special stars | done for what the player knows (systems 401, 142, 238, 476) | the planets' spin (their idle animation: the bands and continents sit elsewhere); city lights; the gas giants' atmosphere halo a little brighter on the dark side; black holes, pulsars and neutron stars drawn from their entities but not checked (the player knows none) |
| 5 | galaxy: terra incognita, borders, hyperlanes, star icons, the core, post effects, the map's names and flags | done at the default camera, a wide view and the whole galaxy (`observe`) | the dust's and nebulae's slow turning (GALAXY_DUST_ROTATION_SPEED); the nebulae's places (InitNebulas); the star labels' icons (section 12); nebula names; from far the territories' coloured edge bands are thinner than the game's (cause not found). The whole galaxy from 2000 of the game's world (`observe`): mean colour (42.5, 36.9, 33.8) against the game's (40.9, 35.2, 32.5); the stars match the game's place, colour and size |
| 6 | ships and stations: empire colours, engine glows, turrets, idle animations | partial | empire colours, the ship shader and lights, turrets and attached entities, additive engine glows: done; idle animations (skeletal .anim) and engine trails not drawn; ships a little small (SHIP_SCALE fitted) |

**The post effects** (`sim/render/src/post.wgsl`, `render.rs`) **[V]**: the passes of
CGameRendering::RenderPostEffects (4.5.2 Linux) with the shaders of `gfx/FX` and the world's
`gfx/worldgfx` settings (`default` for the galaxy and model views, the star class's world such as
`a_star` for a system):

1. the scene is drawn into an RGBA16F target (as the game's CreateRenderTargets: format 0x15 =
   GL_RGBA16F); its alpha is the bloom's emissive mask (opaque meshes write their emissive, additive
   passes alpha², section 8);
2. the bright pass (downsample.shader) at half size: `max(rgb) - bright_threshold`, then
   `x / (0.5 + x)`, plus alpha x `emissive_bloom_strength`; the log luminance in alpha;
3. the average luminance (`exp` of the mean log), clamped to `[hdr_min_adjustment,
   hdr_max_adjustment]`;
4. the bloom, a pyramid: `bloom_iterations` levels (at most `s_BloomIterations[quality]`, 32 at the
   default quality 2) while a level is at least 4 pixels, each blurred along x then y over the whole
   half-size target (CGameRendering::Bloom: a 17-tap Gaussian of `2σ² = max(2 bloom_width², 0.01)`
   normalised x `bloom_scale` per pass, as a centre and four bilinear pairs), added into the
   accumulated bloom (`downsample3`, ONE + ONE, the level's part stretched by BloomToScreenScale),
   then halved into the top left of the cleared level target (`downsample2`);
5. the restore (restorescene.shader): scene + bloom, x `tonemap_middlegrey` / the average
   luminance, Uncharted 2 (W = 11.2), gamma 1/2.2, the world's `color_lut` (32³ cube) and Levels
   (0.04, 0.8).

**The sky** (`sim/render/src/sky.wgsl`) **[V]**: the world's `galaxy_background` cube maps
(`gfx/map/sky_core|mid|rim.dds`, 2048² DXT5 in YCoCg) by the system's `distance_to_core_percent`,
decoded, to linear (2.2), shifted by `galaxy_background_hsv_shift`, through
`galaxy_background_lut`; drawn first at the far plane. The renderer's former dust sprites around a
system are gone (the game has none; they hazed the whole frame through the bloom).

**The mesh shaders** (`sim/render/src/mesh.wgsl`, `src/effects.rs`) **[V]**: a part's effect
(its `shader`) is looked up in `gfx/FX/pdxmesh.shader` (Effect blocks: PixelShader, blend,
rasterizer, Defines), and its defines drive the ports:

- PixelPdxMeshStandard (`standard()`): IS_PLANET, EMISSIVE, NO_PLANET_EMISSIVE, USE_FLOWMAP and
  EMISSIVE_FLOW (the molten planets and gas giants: no normal map, the diffuse at the flow map's
  offset), IS_CLOUDS, IS_RING, ADD_COLOR; ImprovedBlinnPhong (the normalisation capped at 5), the
  back light on planets, the environment map (`environment_map` of the world, its 10 pre-filtered
  levels by glossiness, x `cubemap_intensity`), no ambient (`ambient` has value 0), the emissive
  only on a planet's dark side (`dark x specular.r x NdotL`), x vBloomFactor (the entity's
  `game_data` bloom_factor: the molten planets 1.4), alpha = diffuse alpha x emissive (the
  bloom's mask). A planet's AtmosphereColor.a is 0 (SetPlanetEntityCustomData writes it so): no
  surface tint and no emissive recolouring on planets; their atmosphere is the shell.
- PixelPdxMeshShip (`ship()`): the emissive recoloured by the empire colour x the entity's
  `emissive_recolor_crunch`, the specular map's red the empire colour mask (in gamma space), the
  system light, the culture's three camera lights (`ship_lighting` of
  common/graphical_culture: directions in camera space, left unnormalised as the game's code does;
  the colours `cam_light_N_diffuse` of the world), the ambient and rim light (`ambient`,
  `rim_light_diffuse`; the intensities by the camera's distance, `near_value`..`far_value`). The
  empire colour (PrimaryColor) is the `ship` swatch (flags/colors.txt) of the first of the owner's
  flag colours that has one (CEmpireFlag::GetEntityColor), when the culture has `ship_color`; a
  fleet's owner is the country whose `fleets_manager.owned_fleets` lists it.
- PixelPdxMeshAdditive (`additive()`, ANIMATE_UV at time 0): the diffuse x its alpha, the alpha x
  vBloomFactor, added (engine glows, the black hole's rings and lens).
- The light settings of the world (`system_back_light_diffuse`, `cam_light_*`, `ambient`,
  `rim_light_diffuse`) are made linear twice by the game (^4.84), the lava colours, the planet's
  atmosphere colour and the system light once (^2.2).

**Bodies** (`sim/render/src/system.rs`) **[V]** (CGraphicalMap::SetupPlanetEntityInstance; the
game's `state planet ID` agrees for system 401): a star turned half about y; a planet's z axis
toward the system's centre, raised by PLANET_TILT_FROM_SUN (`z = normalize(-p.x/L, -p.y/L + 0.52,
-p.z/L)`), x level, y = z x x, turned over (x, y negated) when a CCrudeRandom seeded with the
planet's id draws an even number; a ring (binary_flags bit 8, `gas_giant_rings_01_entity`, the
planet's look) the same with PLANET_RING_TILT_FROM_SUN -0.16, drawn on both faces, blended, its
alpha added (BlendStateAlphaBlendWriteAlpha). An entity's `attach` entities are drawn at its
locators. A system's world (post effects, sky, lights, star colours) is its star class's `class`
(common/star_classes: sc_m_giant is `m_star`), a star body's lava colours that of the star class
whose `planet` it is. The default camera: ENTER_SYSTEM_ZOOM_STEP 6, 3 x outer_radius, pitch 50.

**Asteroid belts** **[V]** (CAsteroidGraphics::CalculateAsteroidFields): N = trunc(2 pi R 0.1
density) asteroids (R the belt's inner_radius x 10), at even angles (i pi / (N/2)), the radius R +
80 width t³ (t in [-1, 1)), the height -100 - 40 u, the size 1 + 4 u, a random axis, a slot retried
while it overlaps the last one; the type's meshes (common/asteroid_belts) drawn with
gfx/FX/asteroid.shader (the standard lighting, EMISSIVE for AsteroidEmissive), not their own
shader. The game seeds the field from the clock; the renderer seeds CNoiseRandom with the system's
id. Not done: the asteroid planets' boxes that remove slots, the spin (0.3035 rad/s).

**Ships' turrets** **[V]**: a design section's `component` in a slot: the component template's
`weapon_type_*` tag picks the slot template's entity (common/component_slot_templates `entities`,
the culture's first), drawn at the slot's `locatorname` of the section's mesh.

**Particles** (`sim/render/lua/render/particles.lua`, `src/particles.rs`): an entity state's
`event = { particle = ... }` (the star's `a_class_star_particle`) to the `pdxparticle` of
`gfx/particles/*.gfx`, its `particle` type of the `.asset` files: each subsystem's live particles
(`emission` x mean `life`, at most `max_amount`) at random places of its sphere emitter, each at a
random age with the type's `animation` curves at that age (`size_grow` 1..3, `fade_in_out`), alpha
x 0.8 (PixelParticle), the colour made linear; billboards added with alpha written. Not drawn:
velocity, forces, trails, child systems, rotation over time.

**The galaxy view** (`sim/render/src/scene.rs` `galaxy_3d`, `src/galaxymap.rs`, `src/map.wgsl`;
CGalaxyGraphics, CTerraIncognitaGraphics, CBordersGraphics, CBorderShapeCalculator and the
`galaxy_*.shader`, `border.shader`, `hyperlane.shader` of 4.5.2) in map units (the game's world
/ 2), every texture made linear, then the post effects and sky of the `default` world **[I]** (the
galaxy has no star class; the frames agree):

- **Terra incognita** **[V]**: the player's `country.terra_incognita = { size data systems }`, run
  lengths over a 256² bitmap (the first run unknown), upscaled to 512² and blurred (bloom.shader's
  `bloom_alpha`, sigma about 3 texels); a pixel's value `smoothstep(0.65, 0.75, ti)`
  (terra_incognita.fxh). Outside the known space the stars and the core turn grey (luminance x 0.15),
  the star pins too (x 0.15 x 4), the dust to 0.15 grey (+ 0.3 x a border's alpha); a hyperlane is
  built only when an end is known (HIDE_HYPERLANES_OUTSIDE_TERRA_INCOGNITA) and fades to a grey of
  alpha 0.05. There is no zoom rule for the lanes: their geometry is built from the player's
  terra incognita, and `observe` does not build it again, so the game's observer sees the lanes of
  the player's known space only, from any distance (its frames of the whole galaxy show them
  there and nowhere else) **[V]** frames, the rebuild's trigger **[I]**; Galaxy::lanes_ti keeps
  that terra incognita for the observer.
- **Borders** **[V]**: metaballs per owner on a 2048 grid (35 per owned system, 30 unowned, 20 per
  lane between two systems of one owner; the field `max(0, R²/d² - 1/1.88²)`, threshold 0.05), each
  blob's signed distance (`(d + 15) / 30`) downsampled to 512 and blurred, the owner's colours as
  edge and fill (galaxymap.rs). Only the player's systems and those of countries it has
  communications with have an owner here; the others count as unowned
  (CBorderShapeCalculator::CalculateOwnerIds: CCountry::ListCommunications plus the player; the
  same choice colours the star pins). border.shader's BorderSDF (its edge band and fade by the
  camera's distance) x the raw terra incognita is not drawn itself: the dust (x 0.8) and the nebulae
  (x 0.5, colour x 2) read it under their pixel and take its colour, which is the ring the game
  shows around the home system. Confirmed in the code: CGraphicalMap::Render calls
  CBordersGraphics::Render with pass 0 (BorderSDF into the border target, then BorderCentroid,
  the flags, on the frame's target), then the galaxy, then pass 1, which draws only the StarPin
  effect (the slots: +0x98 BorderCentroid, +0xf0 BorderSDF, +0xc0 StarPin). From far the game's
  coloured edge bands look thicker than the renderer's with the same SDF formula: not explained
  yet (the border target's resolution, or the dust drawn into the galaxy's downsampled target,
  g_nGfxGalaxyDownsample, and stretched, are the candidates).
- **Dust** (galaxy_dust.shader) **[V]** shader, **[I]** placement: a cloud of `dust.dds` at every
  system and int(0.1 R) at random in the core's disc, at radius r x R and angle 2 pi r' (uniform
  in the radius: denser toward the centre) **[V]** (R the core's radius in the game's world, below),
  half size GALAXY_DUST_SIZE + GALAXY_DUST_SIZE_EXTRA x r, up to 10 above or below the
  plane, turned at random, tilted (y += (x + y) x size x 0.1), coloured by `galaxycolor.dds` over
  the systems' bounding box (DustCloudUV), alpha blended.
- **Nebulae** (galaxy_nebula.shader): the save's `nebula = { coordinate radius galactic_object }`: a
  cloud of `nebula.dds` of the nebula's radius and one of 10 + 25 r at each of its systems, 4.5
  below the plane, alpha x 6, coloured by `nebulacolor.dds` at the cloud's own UV (the shader's
  ColorTexture is sampled at the nebula texture's UV; its alpha multiplies the cloud's) **[V]**: a
  sixth map texture (map.wgsl `nebula_colour`). The clouds' places and sizes **[I]**
  (CGalaxyGraphics::InitNebulas not read).
- **The core** (galaxy_center.shader, CGalaxyGraphics::Init) **[V]**: the core's radius R is the
  save's `galaxy.core_radius` (x 2e-5 of its fixed point: the game's world) when above 0.01, else
  the distance from the centre to the nearest system; the quad is +-R (a vertex buffer of four
  corners) and the shader scales it by 1.5, at y -1.5 of the game's world (-0.75 here); the texel
  (sampled linear) x 0.5, added (ONE, ONE), greyed by terra incognita. The renderer had applied
  the x 0.5 before making the texel linear (0.5^2.2 = 0.22): the core was half as bright. Now the
  brightness in 40 px rings about the core is within 0 to 5 % of the game's out to 160 px, at
  pitch 57.5 and 85.
- **Stars** (galaxy_stars.shader), as section 10, added and greyed; **hyperlanes**
  (hyperlane.shader) HYPERLANE_DEFAULT_COLOR about a pixel wide; **star pins** (border.shader
  StarPin, CBordersGraphics::UpdatePins) a hexagon of radius 1 on the plane and a line up to the
  star (the save's `visual_height` / 2), the shown owner's colour at alpha 0.2, else grey 0.5 at
  alpha 0.1.

**The map's names and flags** (`sim/render/src/mapnames.rs`, scene.rs `map_flags_3d`,
`map_names_3d`; mapname.cpp, CBordersGraphics, CBorderBlobCalculator, CGraphicalMap::Render)
**[V]** unless marked:

- **Symbols.** The borders' grid (2048 cells over the game's world -1000 .. 1000; galaxymap.rs
  `owner_grid`) is cut into blobs, 4-connected cells of one shown owner. For each blob the largest
  square of its own cells is kept (a cell's square is 1 + the least of its left, upper and
  upper-left squares; the first largest in row order). A blob whose square is at least
  BORDER_MIN_SIZE_FOR_SYMBOL (16) cells gets a symbol: that square, the cells p + 1 - s .. p + 1,
  in the world at `t x 2000 / 2048 - 1000` (GetCentroidQuads). SBorderData keeps its centre and
  half size (CalculateCentroids).
- **Flags.** The symbol's square x BORDER_FLAG_SCALE (0.6) about its centre, UVs (0, 0) .. (1, 1)
  sampled at (-u, v) (border.shader PixelShaderCentroid: upright from the default camera), alpha
  x 0.65 x the fade. CBordersGraphics::Render's pass 0 draws the border target, sets the frame's
  own target back and draws the flags there, before the galaxy's nebulae, dust and stars, which
  cover them: the renderer draws them first in the background. The texture is the flag's `map`
  emblem alone (`flags/<category>/map/<file>`, white on clear, 256²) **[I]**: how the game makes
  the map flag's texture was not read; its frames show the emblem with no colours.
- **Empire names** (GenerateBorderNames): one per symbol of a country, its text the country's
  name (CCountry +0x1408; the galactic custodian or emperor gets a second line with
  `galactic_custodian` / `galactic_emperor`, and a map filter can show the human player's name:
  neither done), at the centre's x and the centre's z + MAPNAME_BORDER_OFFSET_MUL (0.75) x the half
  size + MAPNAME_BORDER_OFFSET_ADD (4) of the game's world. Its size: the owner's cells along the
  name's row, from the name's column outward, from int(MAPNAME_BORDER_MIN_SIZE / 2 = 50 of the
  world) = 51 cells: the first distance at which either side is another id or the edge, s = that
  x 2000 / 2048 (50 when none); size = s x 0.2 x min(letters, 10).
- **Sector names** (GenerateSectorNames): each sector of the observed country, at its local
  capital's system (`local_capital` is a colony: its planet's system), size = its letters.
- **The text** (AddName, CBitmapFont::FillVertexBuffer): a name's width in the world is its
  scale x its size, the scale MAPNAME_BORDER_SCALE (1) or MAPNAME_SECTOR_SCALE (3) (AddName's
  scale x 20 x size / the text's pixel width, FillVertexBuffer's x 0.05 per pixel): an empire's
  name 0.2 x min(letters, 10) x s wide, a sector's 3 x its letters. Flat on the plane, its x along
  the world's -x and its lines down along +z, centred on its point; vertically centred on the
  line's height plus the font's padding **[I]** (FitTextInternal not read; the line's height alone
  is 5 to 6 font pixels low against the game's frames). Fonts `map_name_border`,
  `map_name_sector` (interface/fonts.gfx: `gfx/fonts/orbitron` in English), the page's colour
  (TextColorAdd 0), alpha x 0.25 (mapname.shader: its `#ifdef IS_NEBULA` is commented out) x the
  opacity, alpha blended, after the galaxy.
- **Which shows** (CGraphicalMap::Render, CBordersGraphics::Render): the empire names and the
  flags while the camera's eye is at least BORDER_NAMES_FADEOUT_ZOOM / BORDER_FLAG_FADEOUT_ZOOM
  (600 of the game's world) above the plane (CGameCamera +0x184: the eye's y, set by
  UpdateInternalCamera), the sector names otherwise (drawn at 1 - the empires' opacity); the
  opacities move by FADEOUT_SPEED (4) x the frame's real time (CGameIdler +0xe0, at most 0.1 s).
  A still frame shows the settled state. Nebula names (GenerateNebulaNames, MAPNAME_NEBULA_SCALE,
  NEBULA_NAMES_FADEOUT_ZOOM 250) are not drawn yet.
- **Against the game** (2210.01.01, 1600x900): at the default camera "Uthab" has the game's text,
  width and place within a pixel; from 1300 of the game's world "Sacred Uthabulan Order" has its
  text and width, 3 px lower (the blob's square comes from the renderer's border grid, not the
  game's). With `observe` (section 9) all 17 countries' symbols get their flags and names where
  the game's do. The game's fade in view mode is slow (its frames are slow): take the third
  `frame` after a camera move.

## 12. The window's controls: the clock, the camera, the selection

The game's behaviour, read from the 4.5.2 Linux build's code **[V]** (inferences marked **[I]**),
and how the renderer does it. Checked against the game's frame after a load (`headless/view.sh`,
the same commands: `H:\code_working\tmp_sym\render3d\parity\7_controls.png`, the game left): the
home system at the same place and scale, the top bar's clock, the outliner.

### The clock (`sim/render/src/clock.rs`)

- **The simulation runs on its own thread**, which owns its Lua runtime (the save with the game's
  definitions and the script layer); nothing of it is shared. Its days run in 1 ms slices (the next
  section). It starts when the clock is first
  unpaused or stepped (the save loads in about 4 s on 10.5.0.24, 8 s on the laptop) and after
  every day publishes a snapshot: the galaxy read from the world, the galaxy view's map textures
  (made again only when the owners or terra incognita changed: their hash), the shown system's
  bodies and ships, the top bar's amounts and the date. The render thread takes the newest
  snapshot when it draws; it keeps its own runtime (the save's world alone) for the game's files
  (models, GUI, worlds) and for what is drawn before the first snapshot. The window never waits for
  a day: Space and the speed are messages to the thread; entering a system asks for its bodies
  and draws the save's until they come.
- **Speeds** (CInGameIdler +0x590, 0..4; Normal and paused after a load): CheckTick posts two
  tick commands every gGameSpeedTurnTimes[speed] = { 0.3 0.15 0.075 0.04 0 } s and a day is ten
  ticks (CGameState::HandleTurnTick), so a day lasts 1.5, 0.75, 0.375, 0.2 s, and at Fastest one
  every five frames. The thread runs a day when it is due; behind, it makes up at most 0.4 of a day
  (the accumulator is clamped to two of a day's five rounds) and otherwise runs as fast as it can.
  The first unpause after a load waits a second more (the accumulator starts at -1). On
  10.5.0.24 a day takes 0.23 to 0.55 s and a snapshot 25 to 70 ms, so Fast and Fastest run at the
  simulation's pace.
- **Pausing keeps the speed**; the speed changes while paused. Keys (CInGameIdler::
  HandleInputEvent): Space pauses or runs; the keypad's + and -, `+` `=` and `-`, Shift+Up and
  Shift+Down change the speed (ModifyGameSpeed: one step, within 1..5); `.` runs one day and
  pauses again (CJumpToNextDayCommand).
- **The top bar** (CMainGui::UpdateTimeWindow; `lua/render/topbar.lua`): paused, `pause_bg_stop`
  (GFX_topbar_paused) and `pause_glow`; running, `pause_bg` (GFX_topbar_running);
  `start_stop_icons` frame 1 (the pause bars) or the speed + 1; `time_description` GAME_SPEED_0
  ("Paused") or the speed's name, localised by the front end; `time` the date as
  CGameDate::GetGameString writes it (`2210.01.01`, not localised). Clicks (CMainGui::Setup):
  `start_stop_icons` and the `hitbox` window pause or run, `increase_speed` and `decrease_speed`
  change the speed; `pause_bg` and `pause_bg_stop` take none. The map screen's clicks reach the
  GUI's buttons first (their hover and pressed frames too); a window's background takes the
  clicks of a window an action names (gui.lua `opts.actions`). Not drawn: the bars' animated
  textures (their `animation` masks).

### The render thread renders only (`sim/render/src/ui.rs`)

The Lua engine does not stop the render. Three threads (and the worker pool's):

- **The simulation's thread** (clock.rs) runs the days in 1 ms slices with every other
  millisecond unused, the Lua VM stopping the engine's code at each slice's deadline
  (docs/frame_timing.md: the patched LuaJIT, the preempter; the worker pool's jobs too), then reads
  the snapshot (whole, between days). That is the default on Linux; on Windows each day runs
  whole (below). STELLAR_RENDER_CLOCK=sliced or =thread chooses.
- **One Lua world.** The simulation's world is the only one: with a simulation the map's runtime
  has the game's files alone (models, GUI, fonts, worlds' graphics), and what is drawn of the world
  (the galaxy, the system shown, the top bar's amounts) comes with the snapshots. A save loaded as
  a world (`load`, the window without `--sim`) has its world in the map's runtime until the
  simulation starts; its first snapshot replaces it (the runtime made anew, the models' index and
  the particles set up again there). A system the snapshot does not carry yet is asked for and
  waited for on the UI thread.
- **The UI thread** owns the app: its Lua runtime (the GUI's layouts, the names' localisation, the
  game's files), the input, the clock's handle and the scene. It runs the jobs the window sends (the
  input), and every 1/120 s while something moves (the clock, the camera, a held key) or after a
  job updates the app, takes the newest snapshot, builds the scene when something changed and
  publishes it with the textures it uses, their mip chains made there.
- **The render (main) thread** draws the newest published scene every 1/120 s. A new scene's
  textures, cube maps and meshes go up at most 4 MB a frame (`Renderer::preload`; the first one
  whatever its size), the scene before drawn until they are all up; then the scene's own buffers.

Before, the render thread built the scene itself when a day's snapshot came: on 10.5.0.24, 7 to 11
ms of it (the selection windows laid out in Lua about 4.2 ms, the galaxy's scene 4.8 ms, the
labels 1.3 ms), and 6 ms more of mip chains when the owners changed.

**`--bench SECONDS`** measures it: the window's way, offscreen (the app on its UI thread, the save
as a running simulation, the galaxy in 3D; the render thread draws the newest scene at 120 FPS,
uploads as above, waits for the GPU's frame; no read-back): 3 s paused, then SECONDS with the clock
at STELLAR_BENCH_SPEED (3). The command protocol's `bench SECONDS [FPS]` does the same on the one
thread the commands run on (the way before). On 10.5.0.24 at 640x360 (the GTX 1080 Ti at its boot
clocks draws the galaxy in 4.2 ms there; at 960x540 it takes 10.4 ms, over the frame alone), 20 s:

| | Normal: frames over 8.33 ms, the longest | Fastest | the render thread's CPU part, the longest |
|---|---|---|---|
| the scene built on the render thread (before) | 52, 18.5 ms | 97, 26.5 ms | 13 to 21 ms |
| the UI thread, the days whole | 0, 6.8 ms | 0, 7.1 ms | 1.8 ms |
| the UI thread, the days in slices | 1 (the GPU's 8.7 ms frame), 8.7 ms | 0, 6.6 ms | 1.8 ms |

A new scene's frame takes the render thread at most about 1 ms (its buffers). The simulation's
slices: 8,038 in 20 s at Normal, 5 longer than 1 ms, the longest 1.22 ms. In slices the
simulation runs at about half its speed: 44 days in 20 s at Normal (51 the game's), 48 at Fastest
(89 with the days whole). (These runs were before the collector's pause below; with it, 30 s at
Normal: no frame over, the render thread's CPU part at most 1.8 ms, 59 days, the slices' longest
21 ms: an atomic step of the collector, which now runs during play.)

**Windows** (the laptop: i7-8705G, 4 cores; Radeon RX Vega M, DX12; the binary cross-compiled
as CI builds it, x86_64-pc-windows-gnullvm), 640x360, 20 s at Normal:

| | frames over 8.33 ms | the render thread's CPU part, the longest |
|---|---|---|
| the scene built on the render thread (before) | 43 | 43.6 ms (scene 24.9, upload 14.0, update 4.7) |
| the UI thread, the days whole | 3 (the GPU's frames, up to 10.7 ms) | 2.0 ms |

At 1280x720 the Vega M's own frames are over 8.33 ms at times (its p99 12.6 ms); the render
thread's part stays under the frame. **The slices on Windows**: a thread woken from a sleep starts
about half a millisecond late (Windows' high resolution timers at their best; 15.6 ms with the
system's default timer, which `cadence::fine_timers` raises to 1 ms), so a slice began half way
into its millisecond, and the simulation ran in slices at 0.35 to 0.40 game days a second where
whole days give 2.25 (the frame timing harness, 10 days). The preempter spins its last 1 ms there
(0.25 ms on Linux; with 0.25 ms half its hooks came more than 0.1 ms late), and the pool's and the
preempter's waits sleep in short high resolution steps; a precise millisecond would need the
unused ones spent waiting. So the days run whole on Windows by default.

**Memory.** The process at 8 GB had four causes; the first three are gone, the fourth bounded:

- a second world: the map's runtime kept the save's world while the simulation ran (above);
- each decoded texture twice: the textures' cache and the scenes' registry each held a copy
  (`dds::Cache` now holds the images shared), and a mip chain's level 0 was a third, made at each
  upload (now the image itself);
- the mip chains made ahead (ui.rs) of the scenes the render thread skipped for newer ones (at the
  fastest speed a day's map textures, 16 MB and more each): kept, 150 MB a second;
- the simulation's heap: stellar_sim's collector pause is 400 (the heap grows to five times its
  live 1.4 GB before a cycle, chosen for speed). The renderer sets 200 before its Lua states are
  made (`runtime::set_gc_pause`; STELLAR_GC_PAUSE overrides; LuaJIT takes a new pause only at a
  cycle's end, so a pause set after the load came too late).

Now (`--bench` prints it): the process at 2.1 GB after the load (the UI thread's runtimes about 90
MB, the decoded textures 157 MB), and at Normal on 10.5.0.24 about 4.1 GB after 30 s (the
simulation's heap at most 2.8 GB); at the fastest speed it levels at 4.5 GB on Linux and moves
between 4.4 and 5.5 GB on Windows, where at 400 it went past 7.6 GB and on. A pause of 150 levels
at 3.7 GB for 14% of the speed. The rest is the worker pool's Lua states, the store (which holds
the part of the world exploration reads, for the workers: docs/data_layer.md), and the GPU
driver's. The renderer does not fault the heap in ahead as the frame timing harness does
(`runtime::prefault_heap`: 3.9 GB at once). On the laptop the window had run out of GPU memory
before its first frame (the Vega M's 4 GB under the process's 8): it draws now.

**The window** keeps one frame in flight: each frame waits for the GPU to finish the one before
(with a mailbox present nothing else holds frames back, and the resources the scenes replace are
freed when the device is polled).

### The camera (`sim/render/src/camera.rs`, `app.rs`; CGameCamera)

- **Input moves a target orientation; the camera follows it** (UpdateOrientation,
  SCameraOffset::SmoothChangeTowards): each frame by min(dt x 6.67, 1) of the way (dt the frame's
  time, at most 0.1 s), position, distance, pitch and yaw alike, the yaw the short way round; while
  the player drags or turns, the position on the plane and the angles at once. Commands (the
  headless renderer) set the camera at once.
- **Zoom steps**: the zoom is the camera's distance. The galaxy's ZOOM_STEPS_GALAXY { 100 200 400
  600 900 1500 3000 } (the game's world; map units / 2), a system's ZOOM_STEPS_SYSTEM_PERCENTAGES
  x 10 x its outer radius. A wheel notch moves one step a frame and scales the target about the
  plane's point under the cursor, which stays under it (SetTargetZoom). Page Up and Page Down held
  zoom by KEYBOARD_ZOOM_RATE x FOCUSED_ZOOM_RATE = 1.5 x the distance a second. Zooming neither
  enters nor leaves a system.
- **Scrolling**: W A S D and the arrows held, and the cursor within EDGE_SCROLLING_PIXELS (3) of
  the screen's edge (toward it from the centre), move the target at scroll_speed (50) x
  SCROLL_SPEED (0.035) x tan(FOV / 2) x the distance a second (0.55 x the distance; diagonals not
  normalised). The middle button drags the plane: the grabbed point stays under the cursor. The
  right button turns (ROTATION_RADIANS_PER_MOUSE_UNIT 0.004 a pixel, from 4 pixels on); on the
  galaxy the yaw springs back to 0 once the button is up (x 0.9 a frame while a radian or more,
  else 0.1 a frame). A left drag is the game's box selection (not done). The target is kept in the
  galaxy's box (+-500 map units) or the system's sphere (outer radius + SYSTEM_CAMERA_RESTRICT_
  EXTRA_SPACE). Shortcuts: R turns the camera back, E and M enter the system under the cursor or
  go between system and galaxy, Home and Backspace go to the capital's system.
- **Entering and leaving** (OnEnterSystem, OnLeaveSystem): a system is entered at its centre,
  pitch 50, flying in from twice its last zoom step to ENTER_SYSTEM_ZOOM_STEP 6 (FOCUS_START_ZOOM_
  STEP 4 when something is followed); one entered before comes back as it was left. Leaving puts
  the galaxy's camera at the system's star, flying out to ZOOM_STEPS_GALAXY[LEAVE_SYSTEM_ZOOM_STEP
  1]. **After a load the home system is shown** at its centre, step 6, pitch 50 (the game's
  `state` after a load: view system 401, distance 11,100, pitch 50; RestoreDeviceObjects'
  FocusOnCoordinate).
- **A double click** focuses (CSelectable::FocusOn): a system from the galaxy is entered; a planet
  or a fleet in a system is followed (the target on it every frame) until the player scrolls or
  drags.

### The selection (`app.rs`, `scene.rs`, `lua/render/windows.lua`, `lua/render/names.lua`)

- **Picking** (CGameState::DoSelection): on the galaxy the first system, in the galaxy's order,
  whose star is within NCamera.SYSTEM_HOVER_RANGE (0.005) of the camera's distance off the mouse's
  ray (FindGalacticObjectUnderMouse: about 7 pixels at 900 lines); fleets are GUI icons in the
  game and take the click first (here the fleet markers drawn with the GUI). In a system
  (GetSelectableAt) the nearest of the ships and bodies along the ray; a ship selects its fleet.
  Clicking empty space clears the selection, Escape too.
- **What opens**: a planet (CPlanet::OnSelect, JumpToColony) `planet_view` (planet_view.gui, at
  100, 100, 1162 x 680); a fleet (CFleetUiHandler::ShowUi) `fleet_view` (fleet_view.gui, lower
  left, one `fleet_view_entry` row: the window grows with it); a starbase `starbase_view`; a
  system nothing (CGalacticObject::OnSelect is empty). Drawn: their frames, the name, the close
  button (which clears the selection); not their lists, tabs and the parts the game fills.
- **The marker**: the game draws none in 3D; the selected thing's map label (below) turns
  RELATION_COLOR_SELECTED_RGB { 1.5 1.1 0 } (GetDiplomaticRelationColor's `selected`). In a
  system that is done; on the galaxy (no star labels yet) a ring in that colour stands in.
- **The outliner** (outliner.gui: `outliner_controller_window`, `tabs_outliner_window`,
  `outliner_tab_window` "Overview"): a group header (`outliner_title_entry_window`) and the
  group's rows (`outliner_member_*_entry_window`) down to the screen's bottom margin; a row's
  background selects its planet or fleet. The order of the groups (COutlinerSettings::GetSort,
  4.5.2 Linux): the settings' tab 0 reads the observer tab's order (libstdc++'s unordered_map
  iterates the tabs 4..0), every Overview group sorts at -1 and the merge sort reverses their
  creation (enum) order: Utility Ships, Military Fleets, Shipyards, Sectors as the frame shows.
  Colonies (PLANETS) are disabled by default (GetDefaultDisabled); empty groups are left out.
  The members (galaxy.lua `outliner`): utility ships by ship class (construction before science
  **[I]**), then the owned-fleet order, their second line the ship size's name; military fleets
  with their strength; starbases with a shipyard module in Shipyards, other upgraded ones in
  Starbases, their second line the save's starbase `type` (sshipyard "Shipyard") and their
  strength; Sectors: a header with the number of sectors, then each sector's header
  (`outliner_sector_title_entry_window`: its name, the number of its colonies) and its colonies
  (the player's planets in its systems), their second line the colony's `final_designation`
  (col_capital "Empire Capital").
  Names from the save are localised by render.names: the name block's key (or literal), its
  `$VAR$` variables, the engine's `%ADJECTIVE%` and `%ACRONYM%` (initials made up to three letters
  from the last word: "Uthabulan Order" UOR); a text wider than its box is cut with " ...".
- **Tooltips: the hook** (`app.rs`): `App::hovered` keeps what the cursor is over (a GUI element's
  path or a pickable thing on the map) and since when; `App::tooltip(rest)` asks a `Tooltips`
  implementation (`text(target, date)`) once the cursor has rested. The next phase implements it
  over the modifier graph, its texts cached with bounded staleness (about a second or 60 frames),
  and draws `core.gui`'s `ToolTipWindow` (GFX_tooltip_bg, `cg_16b`, at most 500 wide). The game's
  builders, for reference: CInGameIdler::BuildToolTip (the map), CFleet / CPlanet /
  CGalacticObject::GetToolTip, the map icons' and COutlinerMember::GetToolTip.

### The main screen's GUI (the game's frame after a load: `parity/8_gui.png`)

- **Map labels in a system** (mapicons.gui; CFleetMapIcon, CPlanetMapIcon, CMapIcon; app.rs
  `system_labels`, scene.rs `add_labels`) **[V]**: every fleet and station has a
  `fleet_map_icon` (at its .gui position (-65, 8) from the fleet's point): its flag, the bars
  (health, armor full; the shield for military fleets, hidden at 0 for the others **[I]**), the
  type icon (GFX_ship_class_small; the frame by what the fleet is, matched by eye: military 3,
  starbase 8, science and research 9, mining 7, construction 2 **[I]**. The game's rule,
  GetShipClassIconFrameFromSize (4.5.2 Linux 0x317e000): the ship size's `ship_class_icon_frame`
  when set (>= 0); else class 7 frame 27, a mobile starbase 31; else a table by EShipClass,
  (3, 2, 14, 1, 15, 7, 9, 1, 6, 13, 8, 28, 1, 62) for 0 to 13. The by-eye frames are this table's
  if military 0, constructor 1, mining station 5, research station 6, colonizer 8, starbase 10;
  the enum's order is not read (its names are runtime lexer tokens, GetShipClassNameFromEnum)) and,
  when its military_power is above 0, its strength (MILITARY_POWER "£military_power£
  $VALUE|*0$": the text icon drawn inline, GFX_text_<name>) and its ship counters
  (`ship_counter_entry` per ship size, GFX_ship_counter_4 for corvettes ... 128 **[I]**, the count,
  tinted). Stations sort with the military in a stack (the frame's order). A planet with an
  owner or deposits has a `planet_map_icon` under it (the planet's point less 0.6 x its display
  size along the camera's up): the name on a plate as wide as the name + 23 (AdjustNameBg), the
  flag at its left (the capital: bg_capital, flag_capital and its decoration), a colony's type and
  health at its right, a `resource_icon_item` per deposit resource (the sum of what its deposits
  produce, the amount in green). Plates, flag frames and type frames take the relation colour
  (CColor::SwitchHSVtoRGB of RELATION_COLOR_PLAYER_HSV: (-0.93, 0.89, 0.61) for the player's,
  grey 0.56 for others). Labels that touch stack (UpdateIconStacks: the first stack a label
  touches, a stack centred on its members' mean centre, the heights summed; inside, the highest
  sort key first: military fleets, civilian fleets, planets, each by id), each at the top centre
  of its slot: the frame's columns of planets 64 px apart and stations 48 apart.
- **Star labels on the galaxy** (`star_mapicon`, app.rs `galaxy_labels`) **[I]**: the name of each
  system in the player's terra incognita on a plate fitted to it, under the star, within
  GALAXY_SHOW_STARNAME_ZOOM (800 of the game's world); the plate in the relation colour, gold when
  selected (the 3D views draw no ring); the fleets are no discs on the 3D galaxy (the game shows
  them in the star labels' presence icons, not drawn yet). The galaxy banner shows the empire's
  name and its government type.
- **Flags** (flag.rs; flag_sprite.shader, flagSpriteType) **[V]**: the background's red, green
  and blue weight the flag's first three colours (flags/colors.txt `flag`), the emblem
  (flags/<category>[/small|/map]/<file>) over it in its rectangle, the alpha cut by the mask, the
  sprite's frame over all, the frame multiplied by ModulateColor (a label's relation colour);
  composed on the CPU once per country, sprite and colour. Drawn: the top-left empire flag
  (`button_topbar_government`, GFX_empire_flag_64 of interface/game_setup/customization.gfx:
  interface/'s subfolders' .gfx files are read too), the banner's, the labels'.
- **Orbits** (CGraphicalMap::Render pass 0, gfx/FX/lines.shader) **[V]**: one-pixel lines,
  128 segments of 3.142 / 64 radians, ORBIT_HSV { 0.44 0.8 0.6 } made linear, alpha 0.1 at zoom
  step 1 down to 0.05 at step 6 (SYSTEM_LINE_ALPHA_FADE_*), under the planets and through the
  post effects; the system's inner border (white) and outer border (SYSTEM_OUTER_BORDER_HSV) at
  the save's radii, every other segment (64 dashes, opposite phases).
- **The top bar's numbers** (resource_groups formats, CreateSIValueNoColor) **[V]**: the
  stockpile, then the month's balance (budget.current_month.balance summed) with its sign; whole
  under 1000, then K and M with one decimal, cut not rounded (9084 "9.0K +75"); research its
  income alone ("+39").
- **The bottom banner** (main_bottom.gui `maingui_bottombar` / `leave_system_window`,
  CMainGuiBottomBarLeaveSystemWindow::Update) **[V]**: "Paused" (GAME_SPEED_0) and its glow while
  paused, the system's name, its type (sys_homeworld for the owner's capital system, else
  colonised, outpost, unclaimed or alien **[I]**: common/system_types' weights not evaluated), the
  owner's flag, the galaxy button; `leave_galaxy_window` on the galaxy (the empire's name). The
  map modes' window and the toolbar (home, find, chat, databank, menu) of the same file. The map
  mode buttons **[V]**: common/map_modes in file order (default, unions, diplomatic, intel,
  opinion, attitude, neighbours; the cosmic storm forecast left out **[I]**), a
  `main_gui_map_mode_entry` each in the gridbox `map_modes` (LOWER_LEFT: from its bottom left,
  four a row, 34 apart), icon GFX_map_mode_<key>, the active one (default, after a load) in frame 2.
- **The left bar** (main.gui `maingui_left_bar_buttons`, collapsed at its hide_position): the
  views' icons (GFX_topbar_<view>_button x 0.6) down its gridbox, in the frame's order
  (situation, council, traditions, technology, leaders, species, empire, expansion planner, fleet
  manager, contacts, discoveries, claims, market) **[I]**; its background (the container
  `background`, GFX_navbar_bg_wide at its 320 x 610, no clip needed: the texture's own right edge
  is the strip's) with its right edge at x = 35 as in the game's frame, 65 left of its (5, 5) in
  the window at the hide position **[I]**: what moves it is not read (CMainGui::
  UpdateLeftBarButtons only sets the window's target position).
- **Alerts** (alerts.gui `alerticon_window`; CAlertManager) **[V]**: from (200, 30), 55 x 72
  apart, five a row, the banner by priority (common/alerts.txt), the alert's icon (a sprite sheet's
  frame: `sprite_sheet_sprite_type`, `default_frame`), in the order of common/alerts.txt's IDs
  within a priority. Read so far (galaxy.lua `alerts`):
  - the research alerts (ID 1 to 3): an area with no `<area>_queue` (ShouldShowTechAlert);
  - `alert_unlock_tradition` (17): the country's unity at the next tradition's cost, (300 +
    (8 x adopted) ^ 1.8) x (1 + 0.002 x empire_size) (00_defines TRADITION_COST_AMOUNTS,
    TRADITION_COST_TRADITION, _EXP, EMPIRE_SIZE_TRADITION_COST_PENALTY) **[I]**: the cost
    modifiers, the slider and the empire size's base are not applied;
  - `alert_first_contact_stage_done` (38): a contact in the country's `first_contact contacts`
    with status in_progress and an unexpired `event`; it sorts as MEDIUM, its banner is LOW (green);
  - `alert_council_agenda_ready_for_activation` (44): government `council_agenda_progress` at
    the agenda's cost (@base_agenda_cost 7000) **[I]**: EMPIRE_SIZE_COUNCIL_AGENDA_COST_PENALTY
    would put the cost over the save's 7008, yet the game shows the alert.
- **Hyperlane exit arrows** (CNavigationArrowManager::InitForSystem, CNavigationArrow::Init;
  system.rs `navigation_arrow`, `arrow_text`) **[V]** for place and turn: one a hyperlane whose
  neighbour the player has discovered (IsDiscoveredBy; here its terra incognita's cleared
  systems **[I]**). The FTL point (CalcFTLPointWith: toward the neighbour at 1.05 x the
  CGalacticObject +0xfe8 radius, the save's inner_radius by the frame) on the bodies' plane
  (DEFAULT_PLANET_PLANE), pushed NAVIGATION_ARROW_OFFSET (150) along its 3D direction from the
  centre; turned about y to atan2(z, x) + 90 degrees (its mesh's -z outward);
  navigation_arrow_entity (scale 60), PdxMeshNavigationButton: the diffuse's first of five
  frames (u x 0.8), unlit, alpha blended, no depth write (Shading::Button; the intel grey and the
  hover, press and selected frames not drawn). The neighbour's name (GetNameForPlayer, a
  CPdx3DTextObject, Text3D: blended, RGB only) at NAVIGATION_ARROW_TEXT_OFFSET (-50) along the
  same direction, its x along the tangent, its up outward, NAVIGATION_ARROW_TEXT_SCALE (1.6) world
  units a pixel of the face, NAVIGATION_ARROW_TEXT_KERNING (8) pixels between letters **[I]**:
  the face is Orbitron's TrueType (32 px); the bitmap gfx/fonts/orbitron stands in, stretched
  1.7 x upright and coloured to the game's frame by eye; centred on its place.

- The left bar's views (one open at a time, `views.rs`, `lua/render/windows/NAME.lua`): the research
  and traditions views in [windows/research.md](windows/research.md).

### Not done yet

- The galaxy star labels' own rules (CGalacticObjectMapIcon not read: owner flags, the capital
  plate, which names show, the fleets' presence icons, the empire's map name); the fleet type
  icon's frame (the rule is read, the EShipClass order is not: by eye now); the capital label's
  flag and health bar positions.
- The arrows' text in the TrueType face (no TrueType rasteriser here), its colour constants
  (SNavigationTextConstants), the arrows' hover and click (to the neighbour).
- Alerts: the other 60 conditions; the tradition and agenda costs' modifiers.
- The left bar background's 65 px offset (by the frame), the thin outline under it in the game.
- The outliner rows' icons (fleet status, leader level, planet portrait, starbase type, status
  lists), the military row's size line ("15/50 (15)"), the location's colour, the frontier
  sector, the tab buttons over Overview, the other tabs, collapsing groups.
- The planet, fleet and starbase windows' contents (their lists and tabs): no game frame to
  check them against (the headless game cannot open a window: no `select`), and the full
  layouts overlap until each window's Update rules (which children show) are read.
- Box selection, right-click orders; the camera's slide between systems, the system camera's
  near and far planes, the zoom on a focused object (CalcMinZoom).
- The headless game has no `speed`, `wait` or `select` (headless/ is not changed here).

## Open questions

- The engine's own code for the 2D map and the GUI is not read (the 3D galaxy's borders, terra
  incognita and star size are: section 11): which name fills `gfx/map/star_classes/%s.dds`;
  the GUI's anchor, margin, percent and `if_scaled_resolution` rules; button frame order; the top
  bar's number formatting and which groups show. In the GOG build these are next: the strings
  above lead to their users.
- Localisation: per-header reading of multi-language files, `$KEY|format$` formats, icons in text.
- The 3D front end scene is not drawn.
- Why AMD's 2018 Windows Vulkan driver draws no lanes (the lane pipeline: an instanced quad with
  `select()` in the vertex shader; replacing `select` with `mix`, a vec4 width attribute, and
  rebinding group 0 did not help).
- **3D, still [I]**: the ships' scale (fitted to one starbase), the planet entity variant
  (`entity` + 1), the star class to `gfx/worldgfx` mapping, the texture lookup order, a repeated
  key's last value, and the lights' strengths. A ship's world transform from the game (`state
  ship ID`: CShipGraphics' entity) would settle the first.
- **3D, to match the game** (sections 10, 11): the lens flare; the star's lava tint (the RE says
  the lava, stone and noise textures are sRGB and the lava colours linear, which gives a purple
  tint the game's frame does not show); black holes, pulsars and neutron stars (drawn, not
  checked: the player of the 2210 save knows none; `observe` shows them all now); the territories' edge
  bands from far (section 11); the map flag's texture.
- **3D, not drawn yet**: animation (skeletons and `.anim`: the ships' idle animations, the
  planets' spin), engine trails, LOD selection, the `PdxMeshShipFlow` shader, city lights,
  shadows, nebula names, the names' fades, the system's hyperlane exits, fleets moving between their
  save positions (they are drawn where the world puts them each day), and smooth transitions
  between the galaxy and a system.
