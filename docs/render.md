# The renderer (4.5.2): the galaxy map, the front end, localisation, fonts, the GPU backends

What the renderer (`sim/render/`, package `stellar-render`) needed to learn about the game's data
to draw the galaxy map of a save, the main screen's top bar, the main menu and the load game window,
and what was learned about the GPU backends on the machines it runs on. The code: `sim/render/src`
(Rust: textures, fonts, borders, the GPU, the checks), `sim/render/lua/render` (Lua: what is read
from the game's files and the save, and the GUI layout), `sim/lua/engine/localisation.lua` (the
texts, shared with the engine).

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
