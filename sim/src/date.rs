//! `CDate` / `CStellarisDate`: `int` hours from 5000 years of 365 days before year 0; game years
//! are 12 months of 30 days (`CStellarisDate::GetYear` subtracts 43,800,000 and counts 360-day
//! years; docs/main_loop.md, "Dates"). `HandleTurnTick` adds 24 hours on the day tick.

use std::fmt;

pub const HOURS_PER_DAY: i32 = 24;
pub const DAYS_PER_MONTH: i32 = 30;
pub const MONTHS_PER_YEAR: i32 = 12;
pub const DAYS_PER_YEAR: i32 = DAYS_PER_MONTH * MONTHS_PER_YEAR;
/// 5000 years of 365 days, in hours.
pub const EPOCH_HOURS: i32 = 43_800_000;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date(pub i32);

impl Date {
    /// `month` 1-12, `day` 1-30.
    pub fn from_ymd(year: i32, month: i32, day: i32) -> Date {
        let days = year * DAYS_PER_YEAR + (month - 1) * DAYS_PER_MONTH + (day - 1);
        Date(EPOCH_HOURS + days * HOURS_PER_DAY)
    }

    /// Days since year 0.
    pub fn days(self) -> i32 {
        (self.0 - EPOCH_HOURS).div_euclid(HOURS_PER_DAY)
    }

    pub fn year(self) -> i32 {
        self.days().div_euclid(DAYS_PER_YEAR)
    }

    /// 0-359 (`CStellarisDate::GetDayOfYear`).
    pub fn day_of_year(self) -> i32 {
        self.days().rem_euclid(DAYS_PER_YEAR)
    }

    /// 0-11, the value `HandleTurnTick` caches at `CGameState +0x128` and compares to start a month.
    pub fn month_index(self) -> i32 {
        self.day_of_year() / DAYS_PER_MONTH
    }

    /// 1-12.
    pub fn month(self) -> i32 {
        self.month_index() + 1
    }

    /// 1-30.
    pub fn day_of_month(self) -> i32 {
        self.day_of_year() % DAYS_PER_MONTH + 1
    }

    pub fn add_days(self, days: i32) -> Date {
        Date(self.0 + days * HOURS_PER_DAY)
    }
}

impl fmt::Debug for Date {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{:02}.{:02}", self.year(), self.month(), self.day_of_month())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calendar() {
        let d = Date::from_ymd(2200, 1, 1);
        assert_eq!(d.0, 43_800_000 + 2200 * 360 * 24);
        assert_eq!((d.year(), d.month(), d.day_of_month()), (2200, 1, 1));
        assert_eq!(format!("{:?}", d.add_days(29)), "2200.01.30");
        assert_eq!(format!("{:?}", d.add_days(30)), "2200.02.01");
        assert_eq!(format!("{:?}", d.add_days(360)), "2201.01.01");
        assert_eq!(d.add_days(359).month_index(), 11);
    }
}
