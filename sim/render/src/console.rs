//! The load screens' console (docs/windows/newgame_start.md section 7): the renderer's own log
//! lines, shown live over the load screen while a game is made or loaded. Not the game's (it has no
//! such panel): drawn apart from the load screen's window, on by default in the window and off when
//! the renderer is driven by commands (`--script`, `--listen`), so parity frames are the game's.
//!
//! Every line the crate writes with `eprintln!` comes here too (main.rs shadows the macro for the
//! whole crate, from every thread: the simulation's thread writes the new game's steps as they
//! finish), and the app's log as the load screen takes it ([`crate::app::App`]).
//!
//! Switches: STELLAR_LOAD_CONSOLE=0 / =1 (off / on whatever the mode), the key ` (`toggle_console`),
//! the command `console on|off`.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// The lines kept (the panel shows the last of them).
const KEEP: usize = 500;

static LINES: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
/// A new number each time a line comes (the panel is laid out again).
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// A text's lines added (blank ones left out).
pub fn push(text: &str) {
    let Ok(mut lines) = LINES.lock() else { return };
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if lines.len() >= KEEP {
            lines.pop_front();
        }
        lines.push_back(line.to_string());
    }
    GENERATION.fetch_add(1, Ordering::Relaxed);
}

/// The last `n` lines, oldest first.
pub fn tail(n: usize) -> Vec<String> {
    match LINES.lock() {
        Ok(lines) => lines.iter().skip(lines.len().saturating_sub(n)).cloned().collect(),
        Err(_) => Vec::new(),
    }
}

pub fn generation() -> u64 {
    GENERATION.load(Ordering::Relaxed)
}

/// Whether the console shows at first: STELLAR_LOAD_CONSOLE=0 or =1, else on in the window and off
/// when driven by commands (`headless`).
pub fn enabled(headless: bool) -> bool {
    match std::env::var("STELLAR_LOAD_CONSOLE").as_deref() {
        Ok("0") | Ok("off") | Ok("no") => false,
        Ok("1") | Ok("on") | Ok("yes") => true,
        _ => !headless,
    }
}

/// A line the panel tints: an error, a failure, a panic.
/// A count of errors ("3 errors", "2 rule errors") is one when not 0; "0 trigger errors" is not.
pub fn is_error(line: &str) -> bool {
    let l = line.to_ascii_lowercase();
    if l.contains("failed") || l.contains("panic") {
        return true;
    }
    let words: Vec<&str> = l.split(|c: char| !c.is_ascii_alphanumeric()).filter(|w| !w.is_empty()).collect();
    for (i, w) in words.iter().enumerate() {
        if !w.starts_with("error") {
            continue;
        }
        // the count a word or two before it, if any
        let count = words[i.saturating_sub(2)..i].iter().rev().find_map(|v| v.parse::<u64>().ok());
        if count != Some(0) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_and_errors() {
        // (other tests write lines too, at the same time)
        push("console test a\n\nconsole test b");
        let t = tail(KEEP);
        let a = t.iter().position(|l| l == "console test a").unwrap();
        assert!(t[a + 1..].iter().any(|l| l == "console test b"));
        assert!(!t.iter().any(|l| l.is_empty()));
        assert!(is_error("new game: runtime error: x"));
        assert!(!is_error("start script: 3 on_actions run; 0 errors"));
        assert!(!is_error("jobs: 2 passes; 0 trigger errors, 0 rule errors"));
        assert!(is_error("start script: 1 init_effects run; 2 errors"));
        assert!(is_error("simulation: snapshot: error reading"));
    }
}
