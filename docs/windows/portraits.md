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
- The framing: the plain layout; `close_up` the portrait's custom values, else scale 2 and
  offset { -25 300 } (the values 01_portraits_mammalian.txt has commented out) **[I]**;
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

## Not done

- The clothes and hair textures (clothes_selector, attachment_selector): the parts keep their
  meshes' own textures (a human man shows the default hair).
- The portraits' animations (the entities' idle states; the meshes are drawn in their bind pose).
- The sprites' masks (`masking_texture`: portrait_mask_fade) and the hologram effect
  (buttonstate_rendertarget_hologram.shader, the council's); the council's "gets flipped".
- The portrait group triggers, the scope random's texture choice, the evolution decals
  (PortraitEvolutionDecal), the hue shift (HUE_SHIFT).
- The rooms and planet backgrounds (`room`, `planet` layouts: the diplomacy and empire views).
