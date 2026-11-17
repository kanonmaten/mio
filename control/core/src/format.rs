//! Numbers and times the way the panel writes them in Swedish.

/// `190000` → `190 000`, with a narrow no-break space as Swedish thousands separator.
pub fn count(value: u64) -> String {
    let digits = value.to_string();
    let mut grouped = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push('\u{202F}');
        }
        grouped.push(digit);
    }
    grouped
}

/// How long ago, from two times in seconds since the epoch: "nyss", "för 5 min sedan", …
pub fn ago(then_seconds: u64, now_seconds: u64) -> String {
    let elapsed = now_seconds.saturating_sub(then_seconds);
    match elapsed {
        0..60 => "nyss".to_owned(),
        60..3_600 => format!("för {} min sedan", elapsed / 60),
        3_600..172_800 => format!("för {} h sedan", elapsed / 3_600),
        _ => format!("för {} dagar sedan", elapsed / 86_400),
    }
}

/// Seconds since the epoch now.
pub fn now_seconds() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

/// Seconds since the epoch from an ISO 8601 UTC time such as `2026-11-17T14:03:12Z`.
pub fn iso_seconds(text: &str) -> Option<u64> {
    let text = text.strip_suffix('Z').or_else(|| text.strip_suffix("+00:00"))?;
    let (date, time) = text.split_once('T')?;
    let mut date = date.split('-').map(|part| part.parse::<i64>().ok());
    let (year, month, day) = (date.next()??, date.next()??, date.next()??);
    let time = time.split('.').next()?;
    let mut time = time.split(':').map(|part| part.parse::<i64>().ok());
    let (hour, minute, second) = (time.next()??, time.next()??, time.next().flatten().unwrap_or(0));
    // Days from the civil date (Howard Hinnant's algorithm).
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    u64::try_from(days * 86_400 + hour * 3_600 + minute * 60 + second).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_group_thousands() {
        assert_eq!(count(0), "0");
        assert_eq!(count(999), "999");
        assert_eq!(count(190_000), "190\u{202F}000");
        assert_eq!(count(1_000_000), "1\u{202F}000\u{202F}000");
    }

    #[test]
    fn relative_times() {
        assert_eq!(ago(100, 130), "nyss");
        assert_eq!(ago(0, 300), "för 5 min sedan");
        assert_eq!(ago(0, 7_200), "för 2 h sedan");
        assert_eq!(ago(0, 3 * 86_400), "för 3 dagar sedan");
        assert_eq!(ago(500, 100), "nyss");
    }

    #[test]
    fn iso_times() {
        assert_eq!(iso_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso_seconds("2026-11-17T14:03:12Z"), Some(1_794_924_192));
        assert_eq!(iso_seconds("2024-02-29T12:00:00.123456Z"), Some(1_709_208_000));
        assert_eq!(iso_seconds("igår"), None);
    }
}
