//! `CFixedPoint`: a signed int64 with 1.0 = 100000 (five decimals), the game's number type for the
//! economy and modifiers (docs/modifiers.md, "Values: CFixedPoint").
//!
//! The game multiplies two values as `a * b` then divides by 100000 with a reciprocal multiply and a
//! shift (`AddModifierEntry`); the rounding of that division (toward zero here) is inferred, not
//! verified against the game's values.

use std::fmt;
use std::ops::{Add, AddAssign, Neg, Sub, SubAssign};

#[derive(Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Fixed(pub i64);

impl Fixed {
    pub const SCALE: i64 = 100_000;
    pub const ZERO: Fixed = Fixed(0);
    pub const ONE: Fixed = Fixed(Self::SCALE);

    pub const fn from_int(v: i64) -> Fixed {
        Fixed(v * Self::SCALE)
    }

    /// From a decimal given in hundredths (`from_centi(-90)` is -0.9).
    pub const fn from_centi(v: i64) -> Fixed {
        Fixed(v * (Self::SCALE / 100))
    }

    pub const fn raw(self) -> i64 {
        self.0
    }

    /// `a * b / 100000`, truncated toward zero.
    pub fn mul(self, o: Fixed) -> Fixed {
        Fixed(((self.0 as i128 * o.0 as i128) / Self::SCALE as i128) as i64)
    }

    /// `a * 100000 / b`, truncated toward zero; 0 when `b` is 0.
    pub fn div(self, o: Fixed) -> Fixed {
        if o.0 == 0 {
            return Fixed::ZERO;
        }
        Fixed(((self.0 as i128 * Self::SCALE as i128) / o.0 as i128) as i64)
    }

    pub fn mul_int(self, v: i64) -> Fixed {
        Fixed(self.0 * v)
    }

    pub fn div_int(self, v: i64) -> Fixed {
        if v == 0 {
            Fixed::ZERO
        } else {
            Fixed(self.0 / v)
        }
    }

    /// The integer part, truncated toward zero.
    pub fn to_int(self) -> i64 {
        self.0 / Self::SCALE
    }
}

impl Add for Fixed {
    type Output = Fixed;
    fn add(self, o: Fixed) -> Fixed {
        Fixed(self.0 + o.0)
    }
}

impl Sub for Fixed {
    type Output = Fixed;
    fn sub(self, o: Fixed) -> Fixed {
        Fixed(self.0 - o.0)
    }
}

impl AddAssign for Fixed {
    fn add_assign(&mut self, o: Fixed) {
        self.0 += o.0;
    }
}

impl SubAssign for Fixed {
    fn sub_assign(&mut self, o: Fixed) {
        self.0 -= o.0;
    }
}

impl Neg for Fixed {
    type Output = Fixed;
    fn neg(self) -> Fixed {
        Fixed(-self.0)
    }
}

impl fmt::Debug for Fixed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let sign = if self.0 < 0 { "-" } else { "" };
        let a = self.0.unsigned_abs();
        write!(f, "{}{}.{:05}", sign, a / 100_000, a % 100_000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arithmetic() {
        let a = Fixed::from_int(3);
        let b = Fixed::from_centi(50);
        assert_eq!(a.mul(b), Fixed::from_centi(150));
        assert_eq!(a.div(b), Fixed::from_int(6));
        assert_eq!(Fixed(-7).mul(Fixed(50_000)), Fixed(-3)); // toward zero
        assert_eq!(format!("{:?}", Fixed::from_centi(-90)), "-0.90000");
    }
}
