# Leader portraits

The leaders' portraits on the views' cards: the research view's head of research, the council's
councilors and ruler, the leaders view's rows and big card, the government view's ruler (every
card laid out by `leaders_common.card` or the research card). Marks: **[V]** read in the game's
files or code, **[I]** inferred.

## What the game does

- A card's portrait is its `character_portrait` icon, a `portraitType` sprite
  (interface/core.gfx: GFX_portrait_character, `_close_up`, `_mid_close_up`, `_hologram`, ...):
  CPortraitObject renders the character into a render target and the icon shows it at the
  icon's scale **[V]**.
- The render target is laid out by gfx/portraits/portraits/00_portraits_main.txt's `character`:
  575 x 380, the entity `orientation = center_down`, `position = { 0 -20 }`, `scale = 24`
  (pixels a model unit), `default_close_up_scale = 2` **[V]**.
- The portrait (gfx/portraits/portraits/*.txt `portraits`): `entity` (gfx/models/portraits),
  `character_textures` (the variations), `clothes_selector`, `attachment_selector` (hair), and
  per portrait `custom_close_up_position_offset` / `_scale`, `custom_mid_close_up_*` **[V]**. A
  species' portrait may be a group (`portrait_groups`: `default`, and `leader`, `species`, `pop`,
  `ruler` sections adding portraits under triggers) **[V]**.
- The texture variation comes from the leader scope's random
  (CPortraitObject::GetRandomCharacterVariationIndex 0x30fbce0: a CCrudeRandom seeded from the
  scope's, weighted variations) **[V]**.
- The parts are drawn with PixelPdxMeshPortrait (gfx/FX/pdxmesh.shader): the diffuse as it is
  (the character's light is painted into its textures), `BlendStateAlphaBlendWriteAlpha`,
  `RasterizerStateNoCulling`, `DepthStencilNoZ` **[V]**. The clothes' and hair's parts take their
  textures from the selectors (PortraitClothes, PortraitHair).

## What the renderer does

- `render/portraits.lua`: the portrait database (the `portraits`, `portrait_groups` and the
  `character` layout), a leader's portrait (its `portrait`, else its species'; a group: one of its
  `leader` section's portraits for the leader's gender, by the leader's id **[I: the triggers not
  evaluated]**, else its `default`), its texture (`character_textures`, by the leader's id **[I:
  not the scope's random]**). `portraits.card` finds the template's `character_portrait` icon in
  interface/paragon_ui_types.gui (its place in its `..._clipping_mask` container, the containers
  between added, its scale, its sprite's `close_up` / `mid_close_up`), and puts an `inset` item
  there: above the clipping container's backgrounds, under the card's texts and icons.
- The framing: the plain layout; `close_up` the portrait's custom values, else scale 1.1 and
  offset { 0 50 }, measured on the game's frame of the creator's portrait grid (the human heads)
  **[I: the game's default_close_up_scale = 2 is not a plain factor here; the custom values, e.g.
  psionic_06's 1.8 and { 30 200 }, are used as they are, as that frame shows]**;
  `mid_close_up` the custom values, else scale 1.5 and offset { 0 220 } (the human portraits'
  heads kept in the target) **[I]**. The offsets are in render target pixels, + y down.
- `src/portraits.rs`: the inset filled with the entity's meshes (the portraits' models are read
  when one is first drawn: render/models.lua `models.portraits`), in an orthographic view: the
  model's bounds' bottom centre at the anchor (`center_down`), 24 x the framing's scale x the
  icon's scale pixels a unit (x the entity's `scale`) **[V for the layout's numbers; the anchor
  on the bounds: I]**. The body's parts take the character texture.
- `Shading::Portrait` (mesh.wgsl kind 9): the diffuse unlit with its alpha, on the ring's
  pipeline (both faces, alpha blended); the meshes in their file's order, with the depth test
  **[I: the game draws them without one]**.
- A container with `clipping = yes` cuts the portrait (to the card too: the expanded card's
  container is `width = 100%`); the council's (no clipping) shows the whole render target.

Checked: the 2210.01.01 save (molluscoid, mol17: the research card, the council's four, the
leaders view's rows and big card) and a new game (humans: the leaders view, the council), in a
real window too (Load Game, the research view, its portrait's click to the council).

## The new game's screens

`render/portraits.lua` also gives the portraits of an empire design (render.creator_rules' table)
and finds a portrait icon anywhere in a .gui (`portraits.element`: the element by its name path
in a window, its parent's clipping, its portraitType's `type` and framing; `portraits.put`: the
inset in the parent's laid out rectangle, cut to a scrolled list's box too):

- `portraits.ruler(design)`: the ruler's portrait (a group: its `game_setup` portraits for the
  ruler's gender, the phenotype-th), its character texture, clothes and hair by the design's
  `texture`, `clothes`, `attachment` indices (the selectors' distinct textures in their order, as
  creator_rules counts the editor's options) **[I]**.
- `portraits.species(design)`: the species' portrait (a group: its `species` section for the
  species' gender, `not_set` as male: the game's frames show Human's men **[I]**).
- The asset selectors (gfx/portraits/asset_selectors): the scope's section (game_setup, species,
  leader, ruler), its first `"x.dds" = { trigger }` that holds (leader_class, gender, always and
  AND / OR / NOT / NOR evaluated; any other trigger false **[I]**), its default, the selector's.
  PixelPdxMeshPortrait's PortraitClothes / PortraitHair are the clothes' and hair's parts'
  diffuses. The leaders' cards use the `leader` section by class (the ruler's: `ruler`).
- Character textures may be `tied_texture = { texture }` blocks (the psionic portraits).
- Room portraits (`type = room`, GFX_portrait_gamesetup_mask): the room's 952 x 340 target, the
  character's target at its lower left (75, 0) **[V: 00_portraits_main.txt `room`]**; the
  layout's `position = { 0 -20 }` read as 20 pixels below the target's bottom (the game's frame
  of the empire selection's room) **[I]**.
- Entity scales by scripted variable (`scale = @humanscale`, 0.81) are resolved
  (render/models.lua): the human portraits were 1 / 0.81 too big.

Drawn: the empire selection's list entries (portrait_container/portrait), its preview's ruler in
the room (portrait_window), the species panel (species_window/portrait), the creator's Species &
Portrait grid (species_portrait_picker_entry) and its preview (the Ruler Appearance editor shows
the ruler there), Game Details' species (species_container/portrait_window).

## The home world and the ship

`portraits.rs` fills `.../model|...` insets too (empire_preview.lua makes them):

- The home world (CSpeciesPreviewWindow::CreateHomeworldPreview 0x3250490 **[V]**: the planet
  class's preview entity, else one of its entities at random): `<class entity>_01_entity`
  **[I: the first variant]**, the class's look (system.rs look_of), in `home_world/3d_icon`
  (200 x 200), lit by customization_view_planet's environment.
- The ship (ShowDesign 0x324d54b: the fake country's GetLatestShipDesignOfClass(3, 2), its
  entity from CreateEntityFromDesign **[V]**): the culture's science ship (`science` size with
  DEFAULT_SCIENCESHIP_SECTION **[I: class 3 by the game's frame, humanoid_01's crescent]**),
  the flag's colours as its PrimaryColor, in `ship_preview/render_target` (396 x 160, the
  button's ship_design_entry_bg.dds stretched under it), seen from yaw 235, pitch 30, fitted to
  the box's width **[I: by the frame]**, lit as the ship designer's view **[I: ship_details_view's
  cubemap 1.7 and ambient wash our ship shading out; the game's is warmer]**. The bioship warning
  only for a culture named bio **[I]**.

Checked against the game's frames (/root/ngf/g/02_select.png, 03_setup.png,
/root/ngc/g_portrait.png, g_ruler.png) and in a real window at 1600 x 900 and 1536 x 864 (New
Game, the selection, Select to Game Details; Create New, Select to the creator).

## Not done

- The creator's grid: the game shows other clothes there (a shared jumpsuit, likely the portrait
  evolution's: not traced); its third row's hexagon backgrounds; the selectors' `random` lists
  (their first entry) and triggers on the owner or the pop.
- The portraits' animations (the entities' idle states; the meshes are drawn in their bind pose).
- The sprites' masks (`masking_texture`: portrait_mask_fade) and the hologram effect
  (buttonstate_rendertarget_hologram.shader, the council's); the council's "gets flipped".
- The portrait group triggers, the scope random's texture choice, the evolution decals
  (PortraitEvolutionDecal), the hue shift (HUE_SHIFT).
- The rooms and planet backgrounds (`room`, `planet` layouts: the diplomacy and empire views).
