//! Kreditmätaren: this month's tokens and estimated cost per task and model, from `usage` in the
//! gateway's `/v2/status`, against a credit limit the user types in. The limit is the panel's own
//! setting and never reaches the gateway (docs/DATAMODELL.md, "Kontrakt efter grillningen").

use crate::ai_settings::{TASKS, provider_name};
use crate::format::count;
use crate::status::Usage;

/// $20, in cents.
pub const DEFAULT_LIMIT_CENTS: u64 = 2_000;
/// The largest limit the field accepts: $100 000.
const MAX_LIMIT_CENTS: u64 = 10_000_000;

/// Yellow from 80 % of the limit, red from 100 %.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CreditLevel {
    Normal,
    Warning,
    Over,
}

/// One row of the meter: a task on a provider and model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreditRow {
    pub task: String,
    pub pair: String,
    pub tokens: String,
    pub cost: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CreditMeter {
    pub month: String,
    pub spent: f64,
    pub limit_cents: u64,
    pub level: CreditLevel,
    pub rows: Vec<CreditRow>,
}

impl CreditMeter {
    pub fn new(usage: &Usage, limit_cents: u64) -> Self {
        let limit = limit_cents as f64 / 100.0;
        let fraction = if limit > 0.0 { usage.estimated_cost / limit } else { 0.0 };
        let level = if fraction >= 1.0 {
            CreditLevel::Over
        } else if fraction >= 0.8 {
            CreditLevel::Warning
        } else {
            CreditLevel::Normal
        };
        let task_label = |task: &str| TASKS.iter().find(|(id, _)| *id == task).map_or(task.to_owned(), |(_, label)| (*label).to_owned());
        let rows = usage
            .entries
            .iter()
            .map(|entry| CreditRow {
                task: task_label(&entry.task),
                pair: format!("{} · {}", provider_name(&entry.provider), entry.model),
                tokens: format!("{} in, {} ut", count(entry.input_tokens), count(entry.output_tokens)),
                cost: entry.estimated_cost.map_or_else(|| "pris saknas".to_owned(), dollars),
            })
            .collect();
        Self { month: usage.month.clone(), spent: usage.estimated_cost, limit_cents, level, rows }
    }

    /// The bar's fill, 0–100.
    pub fn percent(&self) -> f32 {
        if self.limit_cents == 0 { 0.0 } else { ((self.spent * 10_000.0 / self.limit_cents as f64) as f32).clamp(0.0, 100.0) }
    }

    /// "$3,42 av $20 i 2026-11 (17 %)", what the meter says next to its color.
    pub fn summary(&self) -> String {
        let percent = if self.limit_cents == 0 { 0.0 } else { self.spent * 10_000.0 / self.limit_cents as f64 };
        format!("{} av {} i {} ({} %)", dollars(self.spent), dollars(self.limit_cents as f64 / 100.0), self.month, percent.round() as u64)
    }

    /// The word beside the color, so that the color is never alone.
    pub fn level_label(&self) -> &'static str {
        match self.level {
            CreditLevel::Normal => "Inom gränsen",
            CreditLevel::Warning => "Nära gränsen",
            CreditLevel::Over => "Över gränsen",
        }
    }
}

/// `3.42` → `$3,42`; small amounts keep four decimals (`$0,0721`) as the gateway rounds them.
pub fn dollars(amount: f64) -> String {
    let text = if amount != 0.0 && amount.abs() < 0.995 { format!("{amount:.4}") } else { format!("{amount:.2}") };
    format!("${}", text.replace('.', ","))
}

/// What the user typed as limit, in cents: "20", "20,50", "$15.5". `None` for anything else.
pub fn parse_limit(text: &str) -> Option<u64> {
    let text = text.trim().trim_start_matches('$').trim().replace(',', ".");
    let (whole, fraction) = text.split_once('.').unwrap_or((&text, ""));
    if whole.is_empty() || !whole.chars().all(|digit| digit.is_ascii_digit()) || fraction.len() > 2 || !fraction.chars().all(|digit| digit.is_ascii_digit()) {
        return None;
    }
    let cents = whole.parse::<u64>().ok()?.checked_mul(100)? + format!("{fraction:0<2}").parse::<u64>().ok()?;
    (1..=MAX_LIMIT_CENTS).contains(&cents).then_some(cents)
}

/// The limit as the field shows it: `2000` → `20`, `1550` → `15,50`.
pub fn format_limit(cents: u64) -> String {
    if cents.is_multiple_of(100) { (cents / 100).to_string() } else { format!("{},{:02}", cents / 100, cents % 100) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::UsageEntry;

    fn usage(cost: f64) -> Usage {
        Usage {
            month: "2026-11".into(),
            currency: "USD".into(),
            estimated_cost: cost,
            entries: vec![
                UsageEntry { task: "ask".into(), provider: "groq".into(), model: "qwen".into(), input_tokens: 900, output_tokens: 100, ..Default::default() },
                UsageEntry {
                    task: "lesson".into(),
                    provider: "mistral".into(),
                    model: "large".into(),
                    input_tokens: 40_000,
                    output_tokens: 21_000,
                    estimated_cost: Some(0.0721),
                    ..Default::default()
                },
            ],
        }
    }

    #[test]
    fn yellow_from_eighty_and_red_from_a_hundred_percent() {
        assert_eq!(CreditMeter::new(&usage(15.99), DEFAULT_LIMIT_CENTS).level, CreditLevel::Normal);
        assert_eq!(CreditMeter::new(&usage(16.0), DEFAULT_LIMIT_CENTS).level, CreditLevel::Warning);
        assert_eq!(CreditMeter::new(&usage(20.0), DEFAULT_LIMIT_CENTS).level, CreditLevel::Over);
        let over = CreditMeter::new(&usage(31.0), DEFAULT_LIMIT_CENTS);
        assert_eq!((over.percent(), over.level_label()), (100.0, "Över gränsen"));
        assert_eq!(over.summary(), "$31,00 av $20,00 i 2026-11 (155 %)");
    }

    #[test]
    fn rows_name_task_model_tokens_and_cost() {
        let meter = CreditMeter::new(&usage(3.42), DEFAULT_LIMIT_CENTS);
        assert_eq!(meter.summary(), "$3,42 av $20,00 i 2026-11 (17 %)");
        assert_eq!(meter.rows[0], CreditRow { task: "Frågor".into(), pair: "Groq · qwen".into(), tokens: "900 in, 100 ut".into(), cost: "pris saknas".into() });
        assert_eq!((meter.rows[1].task.as_str(), meter.rows[1].tokens.as_str(), meter.rows[1].cost.as_str()), ("Lektioner", "40\u{202F}000 in, 21\u{202F}000 ut", "$0,0721"));
    }

    #[test]
    fn the_limit_field_takes_dollars_and_cents() {
        assert_eq!(parse_limit("20"), Some(2_000));
        assert_eq!(parse_limit(" $15,5 "), Some(1_550));
        assert_eq!(parse_limit("0,01"), Some(1));
        for wrong in ["", "0", "-5", "abc", "1,234", "1e3", "200000"] {
            assert_eq!(parse_limit(wrong), None, "{wrong}");
        }
        assert_eq!((format_limit(2_000), format_limit(1_550)), ("20".to_owned(), "15,50".to_owned()));
        assert_eq!((dollars(0.0), dollars(0.0016)), ("$0,00".to_owned(), "$0,0016".to_owned()));
    }
}
