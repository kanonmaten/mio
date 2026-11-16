//! Calendar rules for source timestamps, proposed times and quota resets. Dates are checked
//! by their written components: an impossible day is refused, never rolled into the next month.

use jiff::Timestamp;
use jiff::tz::{Offset, TimeZone};
use serde_json::Value;

/// Days since 1970-01-01 in the proleptic Gregorian calendar. `day` may overflow the month.
pub fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468 + (day - 1)
}

pub fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    (year_of_era + era * 400 + i64::from(month <= 2), month, day)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][(month - 1) as usize]
}

fn valid_calendar_day(year: i64, month: i64, day: i64) -> bool {
    (1..=12).contains(&month) && day >= 1 && day <= days_in_month(year, month)
}

/// Fixed-width ASCII digits at `start`, as a number.
fn number(bytes: &[u8], start: usize, width: usize) -> Option<i64> {
    let digits = bytes.get(start..start + width)?;
    digits.iter().all(u8::is_ascii_digit)
        .then(|| digits.iter().fold(0, |sum, digit| sum * 10 + i64::from(digit - b'0')))
}

fn literal(bytes: &[u8], index: usize, expected: u8) -> Option<()> {
    (bytes.get(index) == Some(&expected)).then_some(())
}

/// Skips an optional fraction (`.` followed by digits) and returns the index after it.
fn skip_fraction(bytes: &[u8], mut index: usize) -> Option<usize> {
    if bytes.get(index) == Some(&b'.') {
        let first = index + 1;
        index = first;
        while bytes.get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        if index == first {
            return None;
        }
    }
    Some(index)
}

/// ISO-8601 with seconds and an explicit `Z` or `±HH:MM` offset, and real calendar components.
pub fn is_instant(value: &str) -> bool {
    fn parse(bytes: &[u8]) -> Option<bool> {
        let (year, month, day) = (number(bytes, 0, 4)?, number(bytes, 5, 2)?, number(bytes, 8, 2)?);
        let (hour, minute, second) = (number(bytes, 11, 2)?, number(bytes, 14, 2)?, number(bytes, 17, 2)?);
        literal(bytes, 4, b'-')?;
        literal(bytes, 7, b'-')?;
        literal(bytes, 10, b'T')?;
        literal(bytes, 13, b':')?;
        literal(bytes, 16, b':')?;
        let index = skip_fraction(bytes, 19)?;
        let (offset_hour, offset_minute) = match bytes.get(index)? {
            b'Z' if bytes.len() == index + 1 => (0, 0),
            b'+' | b'-' if bytes.len() == index + 6 => {
                literal(bytes, index + 3, b':')?;
                (number(bytes, index + 1, 2)?, number(bytes, index + 4, 2)?)
            }
            _ => return None,
        };
        Some(valid_calendar_day(year, month, day) && hour <= 23 && minute <= 59 && second <= 59
            && offset_hour <= 23 && offset_minute <= 59)
    }
    parse(value.as_bytes()).unwrap_or(false)
}

/// A day without a clock time (`YYYY-MM-DD`): an all-day event or a task due that day.
pub fn is_day(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10 && bytes[4] == b'-' && bytes[7] == b'-'
        && matches!((number(bytes, 0, 4), number(bytes, 5, 2), number(bytes, 8, 2)),
            (Some(year), Some(month), Some(day)) if valid_calendar_day(year, month, day))
}

pub fn is_scheduled(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::String(text) => is_instant(text) || is_day(text),
        _ => false,
    }
}

/// An IANA name (any letter case) or a fixed offset such as `+01:00`, `+0100` or `+01`.
fn time_zone(name: &str) -> Option<TimeZone> {
    let mut characters = name.chars();
    if let Some(sign @ ('+' | '-' | '\u{2212}')) = characters.next() {
        let rest = characters.as_str().as_bytes();
        let (hour, minute) = match rest.len() {
            2 => (number(rest, 0, 2)?, 0),
            4 => (number(rest, 0, 2)?, number(rest, 2, 2)?),
            5 if rest[2] == b':' => (number(rest, 0, 2)?, number(rest, 3, 2)?),
            _ => return None,
        };
        if hour > 23 || minute > 59 {
            return None;
        }
        let seconds = (hour * 3_600 + minute * 60) as i32;
        return Offset::from_seconds(if sign == '+' { seconds } else { -seconds }).ok().map(TimeZone::fixed);
    }
    // "Factory" is the tz database's placeholder for an unset zone, not a place.
    if name.is_empty() || !name.is_ascii() || name.eq_ignore_ascii_case("Factory") {
        return None;
    }
    TimeZone::get(name).ok()
}

pub fn is_time_zone(name: &str) -> bool {
    time_zone(name).is_some()
}

/// A clock time without an offset is local time in the request's time zone. Returns the same
/// wall time with that zone's offset, or `None` when the text is not such a time.
pub fn with_offset(value: &str, zone_name: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let (year, month, day) = (number(bytes, 0, 4)?, number(bytes, 5, 2)?, number(bytes, 8, 2)?);
    let (hour, minute) = (number(bytes, 11, 2)?, number(bytes, 14, 2)?);
    literal(bytes, 4, b'-')?;
    literal(bytes, 7, b'-')?;
    literal(bytes, 10, b'T')?;
    literal(bytes, 13, b':')?;
    let (second, index) = if bytes.get(16) == Some(&b':') { (number(bytes, 17, 2)?, 19) } else { (0, 16) };
    if skip_fraction(bytes, index)? != bytes.len() {
        return None;
    }
    if !valid_calendar_day(year, month, day) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let zone = time_zone(zone_name)?;
    // The offset is the zone's offset at this wall time read as UTC, as the app has always seen
    // it. Years 0000-0099 follow the original contract (read as 1900-1999).
    let lookup_year = if year <= 99 { year + 1_900 } else { year };
    let wall = days_from_civil(lookup_year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
    let offset_seconds = f64::from(zone.to_offset(Timestamp::from_second(wall).ok()?).seconds());
    let minutes = (offset_seconds / 60.0 + 0.5).floor() as i64;
    let repaired = format!("{}T{}:{:02}{}{:02}:{:02}", &value[..10], &value[11..16], second,
        if minutes < 0 { '-' } else { '+' }, minutes.abs() / 60, minutes.abs() % 60);
    is_instant(&repaired).then_some(repaired)
}

/// `Fri, 02 Oct 2026 10:02:00 GMT` as milliseconds since the epoch.
pub fn http_date_ms(value: &str) -> Option<i64> {
    let value = value.trim_matches([' ', '\t']);
    const DAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let bytes = value.as_bytes();
    if bytes.len() != 29 || !value.is_ascii() || !DAYS.contains(&&value[..3]) || &value[3..5] != ", "
        || bytes[7] != b' ' || bytes[11] != b' ' || bytes[16] != b' ' || bytes[19] != b':'
        || bytes[22] != b':' || &value[25..] != " GMT" {
        return None;
    }
    let month = MONTHS.iter().position(|name| *name == &value[8..11])? as i64 + 1;
    let (day, year) = (number(bytes, 5, 2)?, number(bytes, 12, 4)?);
    let (hour, minute, second) = (number(bytes, 17, 2)?, number(bytes, 20, 2)?, number(bytes, 23, 2)?);
    let end_of_day = hour == 24 && minute == 0 && second == 0;
    if !(1..=31).contains(&day) || (hour > 23 && !end_of_day) || minute > 59 || second > 59 {
        return None;
    }
    // Two-digit years as the original parser read them.
    let year = match year { 0..=49 => year + 2_000, 50..=99 => year + 1_900, _ => year };
    Some((days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second) * 1_000)
}

/// The next UTC midnight after `now_ms`, as `YYYY-MM-DDT00:00:00.000Z`.
pub fn next_utc_midnight(now_ms: i64) -> String {
    let (year, month, day) = civil_from_days(now_ms.div_euclid(86_400_000) + 1);
    format!("{year:04}-{month:02}-{day:02}T00:00:00.000Z")
}

/// Exactly a real UTC midnight in the form [`next_utc_midnight`] writes.
pub fn is_utc_midnight(value: &str) -> bool {
    value.len() == 24 && value.ends_with("T00:00:00.000Z") && is_day(&value[..10])
}
