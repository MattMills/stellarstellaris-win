-- render/newgame_creator.lua : the empire creator (customize_species_*.gui) opened from the empire
-- selection (Create New, Edit): session ng-creator builds it. This stand-in shows nothing and goes
-- back at once.
--
--   creator.build(game_dir, db, screen, texture_size, loc, state, base) -> { items, report }
--   creator.act(state, action) -> nil (stay), "done" (state.empire set by
--       render.newgame_setup.set_design) or "cancel"

local creator = {}

function creator.build(game_dir, db, screen, texture_size, loc, state, base)
    return { items = {}, report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }, note = "empire creator: not built yet" }
end

function creator.act(state, action)
    return "cancel"
end

return creator
