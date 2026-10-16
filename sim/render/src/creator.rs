//! The empire creator (docs/windows/newgame_creator.md): its screens and rules are Lua
//! (render.newgame_creator, render.creator_editors, render.creator_rules) in the front end's
//! runtime; render.frontend_newgame shows it as Screen::Creator. These tests run it against the
//! game's files: the rules and their errors, every editor laid out, and a whole design made with
//! the clicks and keys the game took, its text checked against the game's own Save.

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use crate::dds::Cache;

    fn game() -> Option<String> {
        let game = std::env::var("STELLARIS_DIR").unwrap_or_else(|_| "/opt/stellaris".into());
        std::path::Path::new(&game).join("common").exists().then_some(game)
    }

    fn runtime(game: &str) -> stellar_sim::Runtime {
        let cache = Rc::new(RefCell::new(Cache::default()));
        crate::gui::frontend_runtime(game, &cache, "english").expect("the front end's runtime").0
    }

    /// The game's Save (user_empire_designs_v3.4.txt) of the design the headless game made from
    /// the creator's defaults with these inputs: names Human / Humans / Human, United Nations /
    /// Terran, Xenophile then Fanatic Egalitarian, Democratic, Earth, Sol, ruler Ruler
    /// (/root/ngc/flowsave.sh on 10.5.0.24). The flag is the one that game rolled.
    const GAME_SAVE: &str = r#""United Nations"=
{
	key="United Nations"
	ship_prefix=
	{
		key=""
	}
	species=
	{
		class="HUM"
		portrait="human"
		species_name=
		{
			key="Human"
			literal=yes
		}
		species_plural=
		{
			key="Humans"
			literal=yes
		}
		species_adjective=
		{
			key="Human"
			literal=yes
		}
		name_list="HUM1"
		gender=not_set
		trait="trait_organic"
	}
	name=
	{
		key="United Nations"
		literal=yes
	}
	adjective=
	{
		key="%ADJ%"
		variables=
		{
			{
				key="adjective"
				value=
				{
					key="Terran"
					literal=yes
				}
			}
		}
	}
	authority="auth_democratic"
	government="gov_representative_democracy"
	is_nomadic=no
	planet_name=
	{
		key="Earth"
		literal=yes
	}
	planet_class="pc_continental"
	ship_size="civilian_arkship_tier_1"
	system_name=
	{
		key="Sol"
		literal=yes
	}
	initializer=""
	graphical_culture="mammalian_01"
	city_graphical_culture="mammalian_01"
	empire_flag=
	{
		icon=
		{
			category="domination"
			file="domination_11.dds"
		}
		background=
		{
			category="backgrounds"
			file="circle.dds"
		}
		colors=
		{
			"orange"
			"indigo"
			"black"
			"orange"
			"orange"
			"indigo"
		}
	}
	ruler=
	{
		gender=female
		name=
		{
			full_names=
			{
				key="Ruler"
				literal=yes
			}
		}
		portrait="human_female_04"
		texture=0
		evolution_mask=0
		attachment=0
		clothes=4
		leader_class="official"
	}
	spawn_as_fallen=no
	ignore_portrait_duplication=no
	room="default_room"
	spawn_enabled=yes
	ethic="ethic_fanatic_egalitarian"
	ethic="ethic_xenophile"
	origin="origin_default"
}
"#;

    fn lines(s: &str) -> Vec<String> {
        s.lines().map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect()
    }

    // the creator opened on a new design, its owned DLCs the headless reference's
    const OPEN: &str = r#"
        local creator = require('render.newgame_creator')
        local state = { game_dir = RENDER_GAME_DIR, dlcs = {
            ["Ancient Relics Story Pack"] = true, ["Anniversary Portraits"] = true, ["Apocalypse"] = true,
            ["Aquatics Species Pack"] = true, ["Distant Stars Story Pack"] = true, ["Federations"] = true,
            ["Horizon Signal"] = true, ["Leviathans Story Pack"] = true, ["Lithoids Species Pack"] = true,
            ["Megacorp"] = true, ["Necroids Species Pack"] = true, ["Nemesis"] = true, ["Overlord"] = true,
            ["Plantoids Species Pack"] = true }, designs = {} }
        local function build()
            return creator.build(RENDER_GAME_DIR, RENDER_GFX, { width = 1600, height = 900 }, RENDER_TEXTURE_SIZE, RENDER_LOC, state, nil)
        end
        build()
        local function act(a) return creator.act(state, a) end
        local function typ(field, s)
            act('creator:focus:' .. field)
            for c in s:gmatch('.') do act('creator:text:' .. c) end
        end
    "#;

    #[test]
    fn a_new_design_has_the_games_errors() {
        let Some(game) = game() else { return eprintln!("skipped: no game files") };
        let rt = runtime(&game);
        // the game's frame of a new design: Government & Ethics, Empire & Species Names, Homeworld
        // and Ruler Appearance red, with these tooltips
        let errors: String = rt
            .lua
            .load(format!(
                "{OPEN}
                local rules = require('render.creator_rules')
                local ok, all = rules.validate(rules.load(RENDER_GAME_DIR), state.creator.design)
                local out = {{}}
                for _, e in ipairs(rules.EDITORS) do
                    for _, x in ipairs(all[e.key]) do out[#out + 1] = e.key .. ':' .. x.key end
                end
                return tostring(ok) .. ' ' .. table.concat(out, ' ')"
            ))
            .eval()
            .expect("the rules");
        assert_eq!(
            errors,
            "false ethics:CUSTOMIZATION_TOO_FEW_ETHIC_POINTS ethics:GAMESETUP_COUNTRY_INVALID_AUTHORITY \
             names:EMPIRE_DESIGN_SPECIES_NAME_MISSING_FIELD names:EMPIRE_DESIGN_MISSING_EMPIRE_NAME \
             names:EMPIRE_DESIGN_MISSING_EMPIRE_ADJECTIVE homeworld:EMPIRE_DESIGN_MISSING_HOME_WORLD_NAME \
             homeworld:EMPIRE_DESIGN_MISSING_HOME_SYSTEM_NAME ruler:GAMESETUP_LEADER_NAME_MISSING"
        );
    }

    #[test]
    fn the_rules_points_and_picks() {
        let Some(game) = game() else { return eprintln!("skipped: no game files") };
        let rt = runtime(&game);
        let r: String = rt
            .lua
            .load(format!(
                "{OPEN}
                local rules = require('render.creator_rules')
                local R, d = rules.load(RENDER_GAME_DIR), state.creator.design
                local out = {{}}
                local function p(...) out[#out + 1] = table.concat({{ ... }}, ',') end
                -- the ethics: 3 points, one per category (a fanatic replaces its regular), a gestalt
                -- ethic needs all three; the ethics kept in their database order
                act('creator:ethic:ethic_xenophile')
                act('creator:ethic:ethic_fanatic_xenophile')
                p(table.concat(d.ethics, '+'), rules.ethic_points_left(R, d))
                act('creator:ethic:ethic_egalitarian')
                p(tostring(rules.can_add_ethic(R, d, 'ethic_gestalt_consciousness')), rules.ethic_points_left(R, d))
                act('creator:ethic:ethic_authoritarian')
                p(table.concat(d.ethics, '+'))
                -- the authority: democratic needs no authoritarian ethic
                p(tostring(rules.authority_ok(R, d, 'auth_democratic')), tostring(rules.authority_ok(R, d, 'auth_imperial')))
                -- the traits: 2 points and 5 picks for a biological species; organic does not count;
                -- Intelligent costs 2, Unruly gives 2
                p(rules.trait_points_left(R, d), rules.trait_picks_left(R, d))
                act('creator:trait:trait_intelligent')
                act('creator:trait:trait_unruly')
                p(rules.trait_points_left(R, d), rules.trait_picks_left(R, d))
                -- an opposite is refused
                p(tostring((rules.can_add_trait(R, d, 'trait_docile'))))
                return table.concat(out, ' ')"
            ))
            .eval()
            .expect("the rules");
        assert_eq!(
            r,
            "ethic_fanatic_xenophile,1 false,0 ethic_authoritarian+ethic_fanatic_xenophile false,true 2,5 2,3 false"
        );
    }

    #[test]
    fn every_editor_lays_out() {
        let Some(game) = game() else { return eprintln!("skipped: no game files") };
        let rt = runtime(&game);
        let r: String = rt
            .lua
            .load(format!(
                "{OPEN}
                local out = {{}}
                for _, e in ipairs(require('render.creator_rules').EDITORS) do
                    if e.key ~= 'advisor' then
                        act('creator:menu:' .. e.key)
                        local res = build()
                        local buttons = 0
                        for _, it in ipairs(res.items) do
                            if it.button and it.button.action then buttons = buttons + 1 end
                        end
                        if buttons < 15 or #res.report.missing_sprites > 0 then
                            out[#out + 1] = e.key .. ':' .. buttons .. ':' .. table.concat(res.report.missing_sprites, '/')
                        end
                    end
                end
                return table.concat(out, ' ')"
            ))
            .eval()
            .expect("the editors");
        assert_eq!(r, "", "editors with few buttons or missing sprites");
    }

    #[test]
    fn a_design_made_as_in_the_game_is_the_games() {
        let Some(game) = game() else { return eprintln!("skipped: no game files") };
        let rt = runtime(&game);
        let text: String = rt
            .lua
            .load(format!(
                "{OPEN}
                act('creator:menu:names')
                typ('species_name', 'Human') typ('species_plural', 'Humans') typ('species_adjective', 'Human')
                typ('empire_name', 'United Nations') typ('empire_adjective', 'Terran')
                act('creator:ethic:ethic_xenophile') act('creator:ethic:ethic_fanatic_egalitarian')
                act('creator:authority:auth_democratic')
                typ('planet_name', 'Earth') typ('system_name', 'Sol') typ('ruler_name', 'Ruler')
                local rules = require('render.creator_rules')
                local text = rules.to_text(state.creator.design)
                -- Done: civic picks left, the game asks; Yes hands the design to the setup
                assert(act('creator:done') == nil and state.creator.popup.kind == 'unspent', 'the unspent points question')
                assert(act('creator:popup_yes') == 'done', 'done after yes')
                return text"
            ))
            .eval()
            .expect("the design");
        assert_eq!(lines(&text), lines(GAME_SAVE));
    }
}
