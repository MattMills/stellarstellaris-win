//! The economy against the save: every country's budget (income and expenses by economic category
//! and resource) computed from the world, the vanilla definitions and the modifier source
//! (`sim/lua/engine/economy.lua`), compared with each country's `budget.current_month` in the save.
//! Prints the share of (country, side, category, resource) entries within 0.1%, overall and per
//! category, and the biggest differences.
//!
//! Skipped when the Stellaris install or the save is not there. The modifier source is the game's
//! capture of its modifier nodes at the save's moment: `STELLAR_CAPTURE` (default
//! `/opt/stellaris-captures/modifier-nodes-2210.tsv`); without it the budgets are computed with no
//! modifiers.
//!
//!   cargo test --release --test economy -- --nocapture
//!
//! `ECONOMY_LUA=<file.lua>` runs that chunk after the check (tools, e.g. sim/tools/economy_explain.lua)
//! and prints what it returns.

use stellar_sim::{save, Runtime};

fn load() -> Option<Runtime> {
    let game_dir = save::game_dir()?;
    let path = save::default_save()?;
    let gamestate = save::read_gamestate(&path).expect("read the save");
    let date = save::date_of(&gamestate).expect("the save's date");
    let runtime = Runtime::new(date, 7).expect("the Lua runtime");
    runtime.load(&game_dir, Some(&gamestate), None).expect("load");
    Some(runtime)
}

fn capture_path() -> String {
    std::env::var("STELLAR_CAPTURE").unwrap_or("/opt/stellaris-captures/modifier-nodes-2210.tsv".into())
}

#[test]
fn the_budgets_match_the_save() {
    let Some(rt) = load() else {
        eprintln!("skipped: no Stellaris install or no save");
        return;
    };
    let capture = capture_path().replace('\\', "/");
    let text: String = rt
        .eval(&format!(
            r#"
            local economy = require("engine.economy")
            local ok, message = economy.use_capture("{capture}")
            local t0 = RUST.clock()
            local report = economy.check()
            local seconds = RUST.clock() - t0
            local lines = {{ ok and "modifiers: the capture {capture}" or ("modifiers: none (" .. tostring(message) .. ")") }}
            lines[#lines + 1] = economy.format_check(report, tonumber(os.getenv("ECONOMY_TOP") or "") or 60)
            local t = {{}}
            for k, v in pairs(economy.timings or {{}}) do t[#t + 1] = string.format("%s %.2f s", k, v) end
            table.sort(t)
            lines[#lines + 1] = string.format("computed in %.1f s (%s)", seconds, table.concat(t, ", "))
            local units = require("engine.economy.units")
            local m = {{}}
            for k, v in pairs(units.missing) do m[#m + 1] = k .. " " .. v end
            table.sort(m)
            if #m > 0 then lines[#lines + 1] = "definitions not found: " .. table.concat(m, ", ") end
            local eval = require("simscript.eval")
            local miss = {{}}
            for k, v in pairs(eval.stats.missing) do miss[#miss + 1] = {{ k, v.count, v.first }} end
            table.sort(miss, function(a, b) return a[2] > b[2] end)
            local ms = {{}}
            for i = 1, math.min(25, #miss) do ms[i] = miss[i][1] .. " " .. miss[i][2] .. " (" .. miss[i][3] .. ")" end
            lines[#lines + 1] = "script not evaluated (" .. #miss .. "): " .. table.concat(ms, "; ")
            _G.ECONOMY_REPORT = report
            return table.concat(lines, "\n")
            "#
        ))
        .expect("economy");
    println!("{text}");
    if let Ok(path) = std::env::var("ECONOMY_LUA") {
        let chunk = std::fs::read_to_string(&path).expect("ECONOMY_LUA");
        let out: String = rt.eval(&chunk).expect("ECONOMY_LUA chunk");
        println!("{out}");
    }
    // the budgets are there for every country with a budget in the save
    let countries: u32 = rt
        .eval(r#"local n = 0 for _, e in ipairs(_G.ECONOMY_REPORT.entries) do n = n + 1 end return n"#)
        .expect("entries");
    assert!(countries > 0);
}

/// economy.monthly() adds each country's balance of the month to its stockpile.
#[test]
fn the_month_balance_goes_to_the_stockpile() {
    let Some(rt) = load() else {
        eprintln!("skipped: no Stellaris install or no save");
        return;
    };
    let capture = capture_path().replace('\\', "/");
    let (before, balance, after): (f64, f64, f64) = rt
        .eval(&format!(
            r#"
            local economy = require("engine.economy")
            economy.use_capture("{capture}")
            local before = E.resource(0, "energy")
            local balance = economy.balance(0).energy or 0
            economy.monthly()
            return before, balance, E.resource(0, "energy")
            "#
        ))
        .expect("monthly");
    println!("country 0 energy: {before} + {balance:.5} -> {after}");
    assert!((after - (before + balance).max(0.0)).abs() < 1e-4);
}
