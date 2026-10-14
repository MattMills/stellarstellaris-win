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
questions at the end).

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
- **3D**: an orbit camera over the galaxy (stars as billboards, dust above and below the plane,
  nebulae, borders on the plane, lanes and FTL trails in 3D), a system view (its bodies with the
  game's meshes at their save coordinates, orbit rings, ships and stations built from frame and
  section entities) and single models; sizes in the system are the renderer's **[I]** (section 10).
- **Headless, driven by commands** over TCP or from a script, one reply per command after it
  completes (section 9).

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

The map is drawn mirrored in x (the save's x grows to the left), the convention of save viewers
such as Stellaris Dashboard; it is not checked against the game's own camera **[I]**.

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
angles, a system and the models, with frame times. These are looked at, not compared with the
game's pixels (no reference shots yet).

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
  the last part is the shape) or absent (all shapes) **[I]**. `index` is not used **[I]**.
- **an entity** (`.asset`): `entity = { name pdxmesh scale meshsettings attach = { <locator> =
  "<entity>" } state = { ... } locator = { name position rotation } clone = "<entity>" }`. 1,036
  entities attach others; `clone` copies another entity (its mesh and settings, its own settings
  over them **[I]**).
- **the census** (`--model-census`): 6,347 entities load as a model; 1,606 have no pdxmesh (locator
  dummies such as `crystal_ship_small_section_entity`, weapon and hit effects); 1,821 of the loaded
  have no part to draw (frames made of locators, effects). The shaders of the drawn parts:
  PdxMeshShip 4772, PdxMeshShipDiffuseEmissive 692, PdxMeshTerra 327, PdxMeshClouds 283,
  PdxMeshAtmosphere 123, PdxMeshPlanet 84, PdxMeshStar 15, PdxMeshAtmosphereStar 16, others; not
  drawn: Collision 2813 shapes, the additive, flow and alpha-blended effect shaders.
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
  the night side with city lights, not drawn here.
- **The planets' atmosphere tint** (IS_PLANET) **[V]**: `toCamera = saturate(dot(N, -V) + width)`,
  `toSun = dot(N, L) x 0.5 + 0.5`, `a = lerp(toCamera, toCamera x toSun, 0.5)`, the colour mixed
  toward `atmosphere_color` by `a² x intensity`.
- **Clouds** (PdxMeshClouds: the standard shader with IS_CLOUDS) **[V]**: clipped where
  `dot(N, V) < 0.27`, blended by the diffuse alpha.
- **The atmosphere shell** (PixelPdxMeshAtmosphere, `RasterizerStateBack`, additive) **[V]**: the
  colour x 0.15 plus the colour x the star's light x 0.13 x 2, times `(dot(N, -V) x 1.2)⁴`. With
  outward normals only back faces give a non-zero `dot(N, -V)`: the shell is drawn on its back
  faces (front faces culled), brightest behind the planet, a halo around it.
- **The star** (PixelPdxMeshStar) **[V]**: lava and stone textures over a noise, the colours from
  the star class's `gfx/worldgfx/star_<x>_class.txt` (`lava_bright_color`,
  `lava_hot_stone_color`, `lava_cold_stone_color`, each x its `_intensity`; `tex_lava_diffuse` =
  `gfx/worldgfx/lava_d.dds`, `tex_stone_diffuse` = `stone_d.dds`, `tex_lava_noise` a cube map),
  then the class's atmosphere colour toward the limb, a rim x 3.5, x 2. The class `pc_g_star` uses
  the world `g_star` **[I]**. The game samples the noise cube at the direction, x 4 and x 8: the
  same direction, so the same texel three times **[V]** (the code); the renderer uses a value noise
  of the direction instead, and time 0 **[I]**.
- **The star's glow** (PixelPdxMeshAtmosphereStar, additive) **[V]**: the colour x `dot(N, -V)³`,
  alpha `dot(N, -V)⁴`, on the back faces.
- **Ships** (PixelPdxMeshShip): the system light plus the ship camera lights of `gfx/worldgfx`
  (`cam_light_2_diffuse` hsv 0.55 0.4 0.45 from the right, `cam_light_3_diffuse` hsv 0.55 0.35 0.75
  from above) and `rim_light_diffuse` (hsv 0.56 0.5 0.25) **[V]** the colours, **[I]** the
  directions and the rim's range.
- **The environment map** (`cubemap_intensity` 0.4 in worldgfx) **[V]**: drawn as a two-colour
  sky (dark below, grey-blue above the camera), with Schlick's Fresnel and the glossiness **[I]**.
- **Not drawn**: shadows, the tiled point lights, bloom, HDR and tone mapping
  (`tonemap_middlegrey`, `hdr_*`), the colour correction LUTs (`colorcorrection_*.tga`), empire
  colours, city lights, the dissolve and flow effects, animation, the gas giants' and asteroids'
  own shaders (drawn lit).

## 9. The command protocol (headless, TCP)

`stellar-render --listen [ADDR:]PORT` (or `STELLAR_RENDER_LISTEN`; a port alone listens on
127.0.0.1) serves one client at a time; `--script FILE` runs the same commands from a file. One
command per line, one reply per command, sent when the command is complete (a frame is rendered
and written before its reply), so a client scripts exact sequences. Replies: `ok ...` or `error
...`. `sim/render/src/engine.rs`.

| command | reply / effect |
|---|---|
| `load PATH`, `load-sim PATH` | the save's world (fast), or the save as a running simulation |
| `step DAYS` | runs the simulation (a world-only map is loaded again as a simulation first) |
| `view galaxy` / `3d` / `2d` / `system ID` / `model NAME` / `menu` | what the map screen shows |
| `focus system ID`, `focus fleet ID` | the galaxy camera over it |
| `camera X Y Z YAW PITCH DISTANCE` | the camera's target (map x = X, map y = Z), angles in degrees |
| `orbit DYAW DPITCH`, `zoom FACTOR`, `pan DX DY` | relative moves (pan in fractions of the distance) |
| `resize W H`, `key NAME down\|up`, `mouse X Y [left\|right down\|up]`, `scroll DY` | input |
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

## 10. The 3D views

### The camera **[I]**

- **World space**: the galactic plane is y = 0; a map position (x, y) is the point (x, 0, y); a
  system's own space (its planets' and ships' `coordinate` with `origin` the system) the same way.
  Right-handed, depth 0..1. The orbit camera (`sim/render/src/camera.rs`) looks at a target on the
  plane from `distance` at `yaw` (0: from the south, -z) and `pitch` above the plane; at yaw 0
  screen-right is map -x, the same mirror as the 2D map (section 1).
- **Galaxy**: field of view 45° vertical, pitch 60° (30..89°), the distance fitting the galaxy's
  radius (20 to 3x that); near = 1% of the distance, far = 4x + 2000. **A system**: pitch 40°
  (5..89°), the distance 0.62x the fit of its outermost orbit. **A model**: pitch 25°, yaw 35°.
- **Window**: right-drag orbits, left-drag pans, the wheel zooms; W A S D / arrows pan, Q E turn,
  R F tilt, + - zoom, V switches the 2D map and 3D, a click on a star opens its system, Escape
  goes back; Space steps a day, P runs a day per frame.

### The galaxy in 3D **[I]** (the placement), **[V]** (the art, section 1)

Stars are billboards of their class's sprite (at least 5 px); the dust (`dust.dds`, coloured by
`galaxycolor.dds`) billboards with a little height above and below the plane; `center.dds` a
billboard at the centre; the nebulae (the save's top-level `nebula = { coordinate radius name }`,
9 in 2210.01.01) clouds of `nebula.dds` on the plane coloured by `nebulacolor.dds`; the territory
the border texture on the plane; hyperlanes and the fleets' FTL trails lines in 3D. Fleets are
discs in their owner's colour (a fleet's owner is the country whose `owned_fleets` lists it)
**[V]**; a fleet in an FTL state (`movement_manager.state` `move_wind_up`, `move_galaxy`,
`move_jump_anim`, `move_wind_down`; the saves hold the first, the simulation all four) whose
`path` leads to another system draws a trail from where it is to that system **[I]**. On the
running simulation the map is read again after each `step` (2210.01.01 + 6 days: 1 fleet in
`move_galaxy`, 7 winding up, 8 trails).

### The system view

Built from the world on every frame (`sim/render/lua/render/system.lua`, `src/system.rs`), so it
follows the simulation. **[V]** the data: the system's `planet` list (stars are planets whose
class says `star = yes`), each planet's `coordinate`, `planet_size`, `moon_of`, `entity`, class;
the fleets whose `movement_manager.coordinate.origin` is the system and their ships'
`coordinate` and `forward_x`/`forward_y`. **[I]** the drawing: a planet's radius 0.3 x
`planet_size`, a star's 0.45 x (the game's `entity_scale` is read, its use not found); ships and
stations at 0.25 of their model, turned to `atan2(-forward_x, -forward_y)`; the light a point
at the first star; orbit rings around the system's centre (moons: around their planet); the
star's map sprite as a faint halo; a few dust clouds below.

### Frame times

The time of `frame` (scene, upload, the GPU's frame and the read-back; not the PNG's encoding):

| machine | galaxy 1600x900 | system 1600x900 | planet 1024² | ship 1024² |
|---|---|---|---|---|
| 10.5.0.24, GT 730 (NVK, Vulkan) | 295 ms first, 48 to 113 ms | 2.7 s first, 48 ms | 0.75 s first, 37 ms (star) | 24 ms |
| laptop, Radeon RX Vega M GL (DX12) | 519 ms first, 10 to 15 ms | 4.8 s first, 8 ms | 1.3 s first | 24 ms |

The first frames are the textures' loading and decoding on the CPU (the planets' 2048x1024 maps,
the ships' sets). The simulation behind it: `load-sim` 7.7 s, a day 0.35 to 0.6 s.

## Open questions

- The engine's own code for the map and the GUI is not read: which name fills
  `gfx/map/star_classes/%s.dds`; how the border ID and SDF textures are filled (the influence
  factor, lane thickness, ownerless borders); the star icon's size; how the dust clouds are placed;
  the GUI's anchor, margin, percent and `if_scaled_resolution` rules; button frame order; the top
  bar's number formatting and which groups show. In the GOG build these are next: the strings
  above lead to their users.
- The galaxy map's handedness (the x mirror).
- Localisation: per-header reading of multi-language files, `$KEY|format$` formats, icons in text.
- The 3D front end scene and the sky cube map (YCoCg) are not drawn.
- Why AMD's 2018 Windows Vulkan driver draws no lanes (the lane pipeline: an instanced quad with
  `select()` in the vertex shader; replacing `select` with `mix`, a vec4 width attribute, and
  rebinding group 0 did not help).
- **3D, not checked against the game**: no screenshot of the game was compared yet. The game's
  camera (field of view, pitch, zoom limits), the scale of planets, stars and ships in a system
  (how `entity_scale` and `planet_size` combine), ship facing from `forward_x`/`forward_y` and
  `rotation`, the planet entity variant (`entity` + 1), the star class to `gfx/worldgfx` mapping,
  and the texture lookup order are **[I]**. Reference shots from the real game driven by the same
  commands would settle them.
- **3D, not drawn yet**: animation (skeletons and `.anim`), LOD selection, the attachments of
  entities' `attach` (turrets, lights), the ships' empire colours and engine trails, planetary
  rings, asteroid belts, gas giants' and black holes' own shaders, the `PdxMeshShipFlow` and
  additive effect shaders, shadows, bloom, tone mapping and colour correction, the sky box, the
  system's hyperlane exits, fleets moving between their save positions (they are drawn where the
  world puts them each day), and smooth transitions between the galaxy and a system.
