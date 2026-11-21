//! The nightly backup the app sends to the gateway, as `backup` in the gateway's `/v2/status`
//! (docs/DATAMODELL.md, "Kontrakt efter grillningen" → "Säkerhetskopian"). The panel only shows
//! it: the copies are never read, listed or restored from here.

use serde_json::Value;

use crate::format::{ago, iso_seconds};

/// Where the gateway keeps the encrypted copies.
pub const BACKUP_DIRECTORY: &str = "/var/lib/mio-gateway/backups/";

/// The app takes a copy every night while charging, so a copy older than two days means a night
/// was missed twice and someone should look.
pub const STALE_AFTER_SECONDS: u64 = 48 * 3_600;

/// The gateway's summary of the copies it keeps.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct BackupStatus {
    /// Seconds since the epoch of the newest copy; `None` before the first one.
    pub latest_at: Option<u64>,
    /// How many copies are kept (at most 14).
    pub count: u64,
    /// All kept copies together.
    pub bytes: u64,
}

impl BackupStatus {
    /// `None` for a malformed field, which the panel treats like a gateway without backups.
    pub fn parse(body: &Value) -> Option<Self> {
        let latest_at = match body.get("latestAt")? {
            Value::Null => None,
            text => Some(iso_seconds(text.as_str()?)?),
        };
        Some(Self { latest_at, count: body.get("count")?.as_u64()?, bytes: body.get("bytes")?.as_u64()? })
    }

    /// The newest copy is more than 48 hours old. No copy at all is not stale: the app may not
    /// have had its first night yet.
    pub fn is_stale(&self, now_seconds: u64) -> bool {
        self.latest_at.is_some_and(|latest| now_seconds.saturating_sub(latest) > STALE_AFTER_SECONDS)
    }

    /// "i natt 03:12", "i går 23:40", "för 3 dagar sedan", or "Ingen säkerhetskopia än".
    /// `utc_offset` gives the local offset in seconds at a time, so the test needs no time zone.
    pub fn when(&self, now_seconds: u64, utc_offset: impl Fn(u64) -> i64) -> String {
        let Some(latest) = self.latest_at else { return "Ingen säkerhetskopia än".to_owned() };
        let local = |seconds: u64| seconds as i64 + utc_offset(seconds);
        let (then, now) = (local(latest), local(now_seconds));
        let (then_day, now_day) = (then.div_euclid(86_400), now.div_euclid(86_400));
        let minutes = then.rem_euclid(86_400) / 60;
        let (hour, minute) = (minutes / 60, minutes % 60);
        match now_day - then_day {
            0 if hour < 6 => format!("i natt {hour:02}:{minute:02}"),
            0 => format!("i dag {hour:02}:{minute:02}"),
            1 => format!("i går {hour:02}:{minute:02}"),
            _ => ago(latest, now_seconds),
        }
    }

    /// "14 kopior, 12,3 MB".
    pub fn summary(&self) -> String {
        let copies = if self.count == 1 { "1 kopia".to_owned() } else { format!("{} kopior", self.count) };
        format!("{copies}, {}", size(self.bytes))
    }
}

/// `12_345_678` → `12,3 MB`, in powers of 1000 like KDE's file manager by default.
pub fn size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["kB", "MB", "GB", "TB"];
    if bytes < 1_000 {
        return format!("{bytes} byte");
    }
    let mut value = bytes as f64 / 1_000.0;
    let mut unit = 0;
    while value >= 999.95 && unit + 1 < UNITS.len() {
        value /= 1_000.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit]).replace('.', ",")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 2026-11-20 03:12:00 UTC.
    const NIGHT: u64 = 1_795_144_320;
    const HOUR: u64 = 3_600;
    /// Stockholm in winter.
    fn cet(_: u64) -> i64 {
        3_600
    }

    #[test]
    fn the_status_field_follows_the_contract() {
        let backup = BackupStatus::parse(&json!({"latestAt": "2026-11-20T03:12:00Z", "count": 14, "bytes": 12_345_678})).unwrap();
        assert_eq!(backup, BackupStatus { latest_at: Some(NIGHT), count: 14, bytes: 12_345_678 });
        assert_eq!(backup.summary(), "14 kopior, 12,3 MB");
        let none = BackupStatus::parse(&json!({"latestAt": null, "count": 0, "bytes": 0})).unwrap();
        assert_eq!((none.latest_at, none.when(NIGHT, cet), none.is_stale(NIGHT)), (None, "Ingen säkerhetskopia än".to_owned(), false));
        for malformed in [json!(null), json!({"count": 1, "bytes": 1}), json!({"latestAt": "igår", "count": 1, "bytes": 1}), json!({"latestAt": null, "count": -1, "bytes": 0})] {
            assert_eq!(BackupStatus::parse(&malformed), None, "{malformed}");
        }
    }

    #[test]
    fn older_than_48_hours_is_stale() {
        let backup = BackupStatus { latest_at: Some(NIGHT), count: 3, bytes: 1 };
        assert!(!backup.is_stale(NIGHT + 48 * HOUR));
        assert!(backup.is_stale(NIGHT + 48 * HOUR + 1));
        // A clock behind the gateway's is not a stale copy.
        assert!(!backup.is_stale(NIGHT - HOUR));
    }

    #[test]
    fn the_time_reads_as_tonight_yesterday_or_days_ago_in_local_time() {
        let backup = BackupStatus { latest_at: Some(NIGHT), count: 1, bytes: 1 };
        // 04:12 local; seen at 09:00 local the same day.
        assert_eq!(backup.when(NIGHT + 5 * HOUR, cet), "i natt 04:12");
        assert_eq!(backup.when(NIGHT, |_| 0), "i natt 03:12");
        // 16:00 local is in the day, and the next day it was yesterday.
        let afternoon = BackupStatus { latest_at: Some(NIGHT + 12 * HOUR), ..backup.clone() };
        assert_eq!(afternoon.when(NIGHT + 13 * HOUR, cet), "i dag 16:12");
        assert_eq!(afternoon.when(NIGHT + 30 * HOUR, cet), "i går 16:12");
        assert_eq!(backup.when(NIGHT + 3 * 24 * HOUR, cet), "för 3 dagar sedan");
        assert_eq!(backup.when(NIGHT - HOUR, cet), "i natt 04:12");
        assert_eq!(BackupStatus { count: 1, ..Default::default() }.summary(), "1 kopia, 0 byte");
    }

    #[test]
    fn sizes_use_decimal_units_and_a_comma() {
        assert_eq!((size(999), size(1_000), size(999_949), size(999_950), size(3_200_000_000)),
            ("999 byte".into(), "1,0 kB".into(), "999,9 kB".into(), "1,0 MB".into(), "3,2 GB".to_owned()));
    }
}
