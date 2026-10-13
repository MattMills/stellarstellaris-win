//! Diplomacy, wars, federations, the galactic community, espionage, the market (deferred: a stub).
//!
//! Replaces `CWar::DailyUpdateSerial` (`0x8d3c90`), `CWar::OnEnd`, `CWar::UpdatePassiveWarExhaustion`
//! (monthly), `CFederation::DailyUpdateSerial` (`0x665b70`), `CFederationProgression::*` (monthly XP,
//! levels, laws), `CAgreementManager::DailyUpdate` (`0x955920`) / `MonthlyUpdate`,
//! `CCountry::HandleIncomingDiplomacy` (`0x6f2fe0`) / `HandleProposedDiplomacy`,
//! `CGalacticCommunity::DailyUpdate`, `CEspionageOperationManager::DailyUpdate`,
//! `CFirstContact::DailyUpdateSerial`, `CMarket::DailyUpdate`, `CTradeDeal::DailyUpdateSerial`,
//! `CPopFaction::Daily*` (factions). Class census about 202 k instructions (factions 16 k).

use crate::state::World;

/// The galaxy-wide daily work at the end of `DailyUpdate`: not modelled.
pub fn daily(_world: &mut World) {}
