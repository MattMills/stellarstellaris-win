//! The economy windows' buttons (docs/windows/economy.md, "The buttons"): the market's buy and
//! sell, its monthly trades, the expansion planner's rows. Their actions are `economy:...`
//! strings (render/windows/market.lua, expansion_planner.lua); what changes the game state runs
//! where the world is (the map's runtime while it holds the save's world, else the simulation's
//! thread between days: Clock::query), then the open view's data is made again.
//!
//! - `economy:trade:buy|sell:RESOURCE:MULT`: CMarketBuyResourceCommand / CMarketSellResourceCommand
//!   (market.trade: the stockpiles, the fluctuation, the bought and sold totals)
//! - `economy:monthly:add|update|remove:...`: CAddMonthlyTradeCommand, CUpdateMonthlyTradeCommand,
//!   CRemoveMonthlyTradeCommand (market.monthly), the monthly trade window closed after an add,
//!   an edit or a cancel (CMonthlyTradeView::AddTrade / CancelTrade)
//! - `economy:slave:...`, `economy:trade_propose:COUNTRY`: the slave market's and the trade window's
//!   commands, their effects not done here (logged)
//! - `economy:goto:PLANET`: FocusCameraOnObjectOrSystem (CExpansionTargetEntry::OnClickGoto): in
//!   the planet's system, the camera follows it; elsewhere it goes to the planet's system on the
//!   galaxy map; the planner stays open

use crate::app::{App, MapView};
use crate::scene::Pickable;

/// Runs `code` (with `market` = render.windows.market) where the world is; its returned string.
fn world_query(app: &mut App, code: &str) -> Result<String, String> {
    let m = app.map.as_mut().ok_or("no map loaded")?;
    let code = format!("local market = require('render.windows.market') {code}");
    if !m.has_world() {
        let clock = m.clock.as_ref().ok_or("no world: neither the map's nor a simulation")?;
        return clock.query(&code).map_err(|e| format!("render.windows.market (simulation): {e}"));
    }
    m.runtime.lua.load(code).set_name("economy buttons").eval::<String>().map_err(|e| format!("render.windows.market: {e}"))
}

/// The world changed: the open view's data and the top bar made again.
fn changed(app: &mut App) {
    let name = app.open_view.clone();
    if let Some(m) = app.map.as_mut() {
        if let Some(n) = name {
            m.refresh_view(&n, true);
        }
        m.topbar_cache = None;
    }
    app.relayout();
}

fn lua_str(s: &str) -> String {
    format!("{s:?}")
}

pub fn act(app: &mut App, action: &str) -> Result<(), String> {
    let rest = action.strip_prefix("economy:").unwrap_or(action);
    let parts: Vec<&str> = rest.split(':').collect();
    let (cid, game_dir) = match app.map.as_ref() {
        Some(m) => (m.galaxy.player, m.game_dir.clone()),
        None => return Err("no map loaded".into()),
    };
    match parts.as_slice() {
        ["trade", side, key, mult] => {
            let mult: i64 = mult.parse().map_err(|_| format!("bad action {action}"))?;
            let code = format!("return market.trade({cid}, {}, {mult}, {}, {})", lua_str(key), *side == "buy", lua_str(&game_dir));
            let r = world_query(app, &code)?;
            app.log.push(format!("market: {side} {mult} x {key}: {r}"));
            changed(app);
        }
        ["monthly", "add", side, key, amount, price] | ["monthly", "update", side, key, amount, price, _] => {
            let (amount, price): (i64, i64) = (amount.parse().map_err(|_| format!("bad action {action}"))?, price.parse().map_err(|_| format!("bad action {action}"))?);
            let code = if parts[1] == "add" {
                format!("return market.monthly({cid}, 'add', {}, {}, {amount}, {price}, nil, {})", lua_str(key), *side == "buy", lua_str(&game_dir))
            } else {
                let id: i64 = parts[6].parse().map_err(|_| format!("bad action {action}"))?;
                format!("return market.monthly({cid}, 'update', {id}, {}, {}, {amount}, {price}, {})", lua_str(key), *side == "buy", lua_str(&game_dir))
            };
            let r = world_query(app, &code)?;
            app.log.push(format!("market: monthly trade {}: {r}", parts[1]));
            close_monthly(app);
            changed(app);
        }
        ["monthly", "remove", id] => {
            let id: i64 = id.parse().map_err(|_| format!("bad action {action}"))?;
            let r = world_query(app, &format!("return market.monthly({cid}, 'remove', {id}, nil, nil, nil, nil, {})", lua_str(&game_dir)))?;
            app.log.push(format!("market: monthly trade {id} removed: {r}"));
            close_monthly(app);
            changed(app);
        }
        ["goto", planet] => {
            let planet: u32 = planet.parse().map_err(|_| format!("bad action {action}"))?;
            goto(app, planet)?;
        }
        // the slave market's commands (CBuySlaveFromMarketCommand, CRetractSlaveFromMarketCommand,
        // CPutSlaveOnMarketCommand): their effects not done here (the galactic market is not
        // founded in the saves at hand: the game cannot show the tab); Put on Market closes the
        // Sell Slaves window as the game's does
        ["slave", what, ..] => {
            app.log.push(format!("  slave market: {what}: not done here"));
            if *what == "put" {
                app.set_view_state(&[("pool", ""), ("pool_selected", ""), ("pool_open", ""), ("pool_species", ""), ("pool_dropdown", "")]);
            }
        }
        // the trade window's Propose (CDiploActionProposeCommand [not done here: the AI's answer]);
        // the window closes, as the game's
        ["trade_propose", country] => {
            app.log.push(format!("  trade proposal to {country}: not done here"));
            app.close_view();
        }
        _ => app.log.push(format!("  {action}: not done yet")),
    }
    Ok(())
}

/// The monthly trade window closed (its keys out of the market's state).
fn close_monthly(app: &mut App) {
    let keys: Vec<String> = app.view_state.keys().filter(|k| k.starts_with("monthly")).cloned().collect();
    let pairs: Vec<(&str, &str)> = keys.iter().map(|k| (k.as_str(), "")).collect();
    app.set_view_state(&pairs);
}

/// FocusCameraOnObjectOrSystem(planet): the system shown is the planet's: the camera follows the
/// planet; else the galaxy map's camera over the planet's system (not entering it).
fn goto(app: &mut App, planet: u32) -> Result<(), String> {
    let system = app
        .map
        .as_ref()
        .and_then(|m| m.galaxy.planets.iter().find(|p| p.id == planet).map(|p| p.system))
        .or_else(|| {
            // a planet not the player's (the planner's targets): its system from the world
            let m = app.map.as_ref()?;
            let code = format!("local w = require('engine.world') local p = w.object('planet', {planet}) return tostring(p and w.path(p, 'coordinate', 'origin') or -1)");
            let s = if m.has_world() { m.runtime.lua.load(code).eval::<String>().ok() } else { m.clock.as_ref()?.query(&code).ok() };
            s.and_then(|v| v.parse::<i64>().ok())
        })
        .ok_or(format!("planet {planet}: no system"))?;
    let index = app.map.as_ref().and_then(|m| m.galaxy.systems.iter().position(|s| s.id as i64 == system));
    let Some(index) = index else { return Err(format!("planet {planet}: system {system} not known")) };
    match app.view {
        MapView::System(i) if i == index => app.focus(Pickable::Body(planet)),
        _ => {
            if app.view != MapView::Galaxy {
                app.show_galaxy();
            }
            // (the camera slides there as the game's does: its goal, the window moves it)
            let (x, y) = app.map.as_ref().map(|m| (m.galaxy.systems[index].x, m.galaxy.systems[index].y)).unwrap_or_default();
            if let Some(g) = app.goal_mut() {
                g.target = crate::math::V3(x, 0.0, y);
            }
            app.relayout();
            Ok(())
        }
    }
}
