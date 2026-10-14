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

Machines: `10.5.0.24` (Linux, GT 730 with NVK, Mesa 26.0.8; game data in `/opt/stellaris`, saves in
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
- **Backends:** Vulkan on Linux (NVK on the GT 730 renders correctly); DX12 on Windows by default,
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
  the map's names. The next phase, the window's own controls: section 12.
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

- **wgpu 30.0.1** with winit 0.30.13. On 10.5.0.24: Vulkan; NVK (Mesa 26.0.8) on the GT 730
  (GK208B, Kepler) renders correctly offscreen; under Xvfb it cannot present (no DRI3), so a window
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
- **Limits**: `Limits::downlevel_defaults().using_resolution(adapter.limits())` (2048 textures at
  least; the 2048² colour maps and border texture fit). `write_texture` needs no row alignment;
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
| `load PATH`, `load-sim PATH` | the save's world (fast), or the save as a running simulation |
| `step DAYS` | runs the simulation (a world-only map is loaded again as a simulation first) |
| `view galaxy` / `3d` / `2d` / `system ID` / `model NAME` / `menu` | what the map screen shows |
| `focus system ID`, `focus fleet ID` | the galaxy camera over it |
| `camera X Y Z YAW PITCH DISTANCE` | the game's camera (section 10): its target (map x = X, map y = Z), angles in degrees, the distance in map units |
| `orbit DYAW DPITCH`, `zoom FACTOR`, `pan DX DY` | relative moves (pan in fractions of the distance) |
| `resize W H`, `key NAME down\|up`, `mouse X Y [left\|right down\|up]`, `scroll DY` | input |
| `gui off\|on`, `pause` | the GUI (the top bar, a system's orbit lines) hidden or shown; ok |
| `frame PATH.png` | `ok frame PATH W H MS` (MS: scene, upload, GPU and read-back) |
| `frame -` | `ok frame - W H MS BYTES`, then the PNG's bytes |
| `state` | JSON: screen, view, camera, date, systems, fleets by movement state, FTL trails, size |
| `quit` | ends the server |

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
  orientation (x to the left, y downwards). Window: right-drag orbits, left-drag pans, the wheel
  zooms; W A S D / arrows pan, Q E turn, R F tilt, + - zoom, V switches the 2D map and 3D, a click
  on a star opens its system, Escape goes back; Space steps a day, P runs a day per frame.

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
| galaxy | the stars' places and icon size; terra incognita; the player's border ring; the dust, the nebulae, the hyperlanes and star pins; the post effects and sky | the core's glow (half as bright in a wide view); the map's names and flags (section 11) |

### Frame times

The time of `frame` (scene, upload, the GPU's frame and the read-back; not the PNG's encoding):

| machine | galaxy 1600x900 | system 1600x900 | planet 1024² | ship 1024² |
|---|---|---|---|---|
| 10.5.0.24, GT 730 (NVK, Vulkan) | 295 ms first, 48 to 113 ms | 2.5 s first, 40 to 50 ms | 0.65 s first, 37 ms (star) | 24 to 70 ms |
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
| 5 | galaxy: terra incognita, borders, hyperlanes, star icons, the core, post effects | done at the default camera and a wide view | the core's glow half as bright as the game's in a wide view (its quad's size **[I]**); the map's country names, flags and system names (CBordersGraphics::UpdateMapNames); the dust's and nebulae's slow turning (GALAXY_DUST_ROTATION_SPEED); the nebulae's colour is `nebulacolor.dds`' mean, not sampled per pixel |
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
  alpha 0.05.
- **Borders** **[V]**: metaballs per owner on a 2048 grid (35 per owned system, 30 unowned, 20 per
  lane between two systems of one owner; the field `max(0, R²/d² - 1/1.88²)`, threshold 0.05), each
  blob's signed distance (`(d + 15) / 30`) downsampled to 512 and blurred, the owner's colours as
  edge and fill (galaxymap.rs). Only the player's systems and those of countries it has
  communications with have an owner here; the others count as unowned
  (CBorderShapeCalculator::CalculateOwnerIds: CCountry::ListCommunications plus the player; the
  same choice colours the star pins). border.shader's BorderSDF (its edge band and fade by the
  camera's distance) x the raw terra incognita is not drawn itself: the dust (x 0.8) and the nebulae
  (x 0.5, colour x 2) read it under their pixel and take its colour, which is the ring the game
  shows around the home system.
- **Dust** (galaxy_dust.shader) **[V]** shader, **[I]** placement: a cloud of `dust.dds` at every
  system and int(0.1 R) at random in the core's disc (R the save's `galaxy.core_radius` in the
  game's world), half size GALAXY_DUST_SIZE + GALAXY_DUST_SIZE_EXTRA x r, up to 10 above or below the
  plane, turned at random, tilted (y += (x + y) x size x 0.1), coloured by `galaxycolor.dds` over
  the systems' bounding box (DustCloudUV), alpha blended.
- **Nebulae** (galaxy_nebula.shader): the save's `nebula = { coordinate radius galactic_object }`: a
  cloud of `nebula.dds` of the nebula's radius and one of 10 + 25 r at each of its systems, 4.5
  below the plane, alpha x 6, in `nebulacolor.dds`' mean colour **[I]**.
- **The core** (galaxy_center.shader): `center.dds` x 0.5 on a quad of half size 1.5 x
  core_radius **[I]** at y -0.75, added (ONE, ONE), greyed by terra incognita.
- **Stars** (galaxy_stars.shader), as section 10, added and greyed; **hyperlanes**
  (hyperlane.shader) HYPERLANE_DEFAULT_COLOR about a pixel wide; **star pins** (border.shader
  StarPin, CBordersGraphics::UpdatePins) a hexagon of radius 1 on the plane and a line up to the
  star (the save's `visual_height` / 2), the shown owner's colour at alpha 0.2, else grey 0.5 at
  alpha 0.1.

## 12. Next: the window's own controls driving the simulation (handover)

The goal: the date, speed, pause, camera and selection controllable from the window as in the
game. What is there today:

- **The command layer** (`src/engine.rs`, section 9): `load`, `load-sim`, `step DAYS`, `view`,
  `focus`, `camera`, `orbit`/`zoom`/`pan`, `key`, `mouse`, `scroll`, `resize`, `gui`, `frame`,
  `state` (JSON with the date). `pause` only replies ok. `step` runs synchronously. A save loaded
  with `load` is a world only; the first `step` loads it again as a simulation (7.7 s).
- **The app** (`src/app.rs`): the screens (menu, load, map) and views (galaxy 2D/3D, system,
  model), the camera moves, `step(days)` (Map::step in main.rs: Simulation::run_days, then the
  galaxy, borders and map textures read again), keys (W A S D pan, Q E turn, R F tilt, + - zoom, V
  2D/3D, Escape back). A left click on a galaxy star opens its system. `act()` handles only the
  front end's buttons (`exit`, `open_load`, `close_load`, `load:N`). `button_at` returns nothing on
  the map screen, so the top bar's buttons take no clicks.
- **The window** (`src/window.rs`, winit): Space steps a day and P runs a day per frame, both on
  the UI thread (0.35 to 0.6 s a day, so the window stalls while it runs).
- **The GUI** (`src/gui.rs`, `lua/render/gui.lua`, section 2): .gui windows laid out with
  sprites, frames, hover and pressed states, and texts. `lua/render/topbar.lua` binds the top bar
  (`interface/main.gui` `maingui`): the resource amounts and the date (`time_window/time`) from the
  world. The speed controls are drawn in the paused state (`pause_bg`, `pause_glow` hidden).

What is missing:

1. **A clock and speeds.** The simulation runs off the UI thread (a worker that owns the Lua
   runtime, which is not Send, and hands back the extracted galaxy and system data after each day),
   paced by speed: 1 to 5 days per real time, with the length of a day at each speed to be read from
   the engine (it is not in the defines). Pausing stops the worker between days.
2. **The top bar's time controls.** `maingui/time_window`: `decrease_speed` and `increase_speed`
   (shortcuts KP_MINUS, KP_PLUS), `start_stop_icons` and the `hitbox` (pause), `pause_bg` /
   `pause_bg_stop` (`GFX_topbar_running` / `GFX_topbar_paused`), `pause_glow`, the speed strip
   `strip_gamespeed` (`GFX_speed_indicator`, 6 frames), `time_description`. The work: clicks on the
   map screen go to the GUI's buttons first (`button_at` on Screen::Map), `act()` maps these buttons
   to pause, speed down and speed up, and the top bar shows the state (sprite frames, the strip's
   frame = the speed, `time_description` text). The date already follows the world once the top
   bar is built again after each day.
3. **Keys as in the game.** Space pauses (now: a step); the keypad's + and - change the speed (now:
   + and - zoom; the game zooms with the wheel and its zoom keys).
4. **The camera.** The moves exist. Missing: the game's smoothing toward a target orientation
   (CGameCamera +0x230), the zoom steps (ZOOM_STEPS_GALAXY, ZOOM_STEPS_SYSTEM_PERCENTAGES), edge
   scrolling (SCROLL_SPEED), focus on a double click or an outliner entry, and leaving a system by
   zooming out.
5. **Selection.** Nothing is selected today. Needed: a selection in App (system, planet, fleet,
   starbase); picking in the system view (bodies and ships projected and hit-tested, as `star_at`
   does for the galaxy); the selection marker; the outliner and the planet and fleet windows laid
   out by gui.lua with bound data (as topbar.lua does); right-click orders (move a fleet) passed to
   the simulation's order functions.
6. **Commands to test it.** `pause on|off`, `speed N` and `select KIND ID` in engine.rs (clicks
   are `mouse X Y left down` and `up`), and the speed, pause and selection in `state`, so one
   command file drives both the renderer and the game (`headless/view.sh` already serves `pause`).

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
  tint the game's frame does not show); the galactic core's glow (its quad's size and the core
  dust's placement are not read from the code); black holes, pulsars and neutron stars (drawn,
  not checked: the player of the 2210 save knows none).
- **3D, not drawn yet**: animation (skeletons and `.anim`: the ships' idle animations, the
  planets' spin), engine trails, LOD selection, the `PdxMeshShipFlow` shader, city lights,
  shadows, the map's names and flags, the system's hyperlane exits, fleets moving between their
  save positions (they are drawn where the world puts them each day), and smooth transitions
  between the galaxy and a system.
