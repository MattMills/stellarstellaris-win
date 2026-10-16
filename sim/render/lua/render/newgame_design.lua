-- render/newgame_design.lua : the texts and icons the new game's screens show for an empire
-- design: the empire selection's list entries (name, government, species class) and Game Details'
-- player and species boxes (game_setup/setup.gui player_container, species_container).
--
--   local design = require("render.newgame_design")
--   design.texts(game_dir, loc, entry) -> { name, government, species_name, species_class,
--       authority, origin, player, authority_icon, origin_icon }
--
-- entry: an entry of render.newgame_setup's design list ({ kind = "prescripted", key, block } or
-- { kind = "custom", design }, the creator's table) or the empire chosen (state.empire: the same
-- with `design`). A prescripted block becomes a design table through render.creator_rules.
-- The game's Game Details frame for the creator's flow (flow.sh: United Nations, Human, Democratic,
-- Prosperous Unification) shows these texts; the player's name is "unknown" there [V: the frame;
-- I: the profile has no user name].

local rules = require("render.creator_rules")
local C = require("render.windows.empire_common")

local design = {}

local function design_of(entry)
    if type(entry) ~= "table" then
        return nil
    end
    if type(entry.design) == "table" then
        if entry.design.species and type(entry.design.species) == "table" then
            return entry.design
        end
        return rules.from_block(entry.design, entry.key)
    end
    if entry.block then
        return rules.from_block(entry.block, entry.key)
    end
    if entry.species and type(entry.species) == "table" then
        return entry
    end
    return nil
end

-- a name the player typed (literal) or a localisation key
local function text_of(ctx, s)
    if not s or s == "" then
        return ""
    end
    if ctx.loc and ctx.loc.has(s) then
        return C.loc(ctx, s)
    end
    return s
end

function design.texts(game_dir, loc, entry)
    local d = design_of(entry)
    if not d then
        return {}
    end
    local ctx = { game_dir = game_dir, loc = loc }
    local gov = d.government
    if not gov or gov == "" then
        local ok, R = pcall(rules.load, game_dir)
        gov = ok and rules.government(R, d) or nil
    end
    local t = {
        name = text_of(ctx, d.name),
        government = gov and C.loc(ctx, gov) or "",
        species_name = text_of(ctx, d.species.name),
        -- the class's name (name_lists: HUM "Humanoid")
        species_class = C.loc(ctx, d.species.class or ""),
        authority = d.authority and C.loc(ctx, d.authority) or "",
        origin = d.origin and C.loc(ctx, d.origin) or "",
        player = "unknown",
    }
    if d.authority then
        t.authority_icon = C.icon_file(ctx, "common/governments/authorities", d.authority,
            "gfx/interface/icons/governments/authorities/" .. d.authority .. ".dds")
    end
    if d.origin then
        t.origin_icon = C.icon_file(ctx, "common/governments/civics", d.origin,
            "gfx/interface/icons/governments/civics/" .. d.origin .. ".dds")
    end
    return t
end

return design
