//! Övervakning: which desktop notifications to show, and when not to repeat one. A service that
//! stops, or starts more than three times in ten minutes (a crash loop that systemd keeps
//! restarting), is told once; the same notification is never shown again within ten minutes,
//! so a flapping service does not fill the notification list.

use std::collections::BTreeMap;

use crate::status::{Alert, Overview, alerts};

/// The watch window, in seconds: restarts are counted and repeats suppressed over ten minutes.
pub const WINDOW_SECONDS: u64 = 600;
/// More starts than this within the window is a restart loop.
pub const MAX_STARTS: usize = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Service {
    Gateway,
    Pianissimo,
}

impl Service {
    const ALL: [Service; 2] = [Service::Gateway, Service::Pianissimo];

    fn starts(self, overview: &Overview) -> Option<&Vec<u64>> {
        match self {
            Service::Gateway => overview.recent_starts.gateway.as_ref(),
            Service::Pianissimo => overview.recent_starts.pianissimo.as_ref(),
        }
    }

    fn alert(self, count: usize) -> Alert {
        let (title, consequence) = match self {
            Service::Gateway => ("AI-gatewayen startar om gång på gång", "Telefonen får kanske inga AI-svar."),
            Service::Pianissimo => ("Pianissimo startar om gång på gång", "Telefonen får kanske ingen text."),
        };
        Alert { title: title.to_owned(), body: format!("{count} starter på tio minuter. {consequence} Se loggen i Mio Kontroll.") }
    }
}

/// Starts within the window ending at `now`.
pub fn starts_in_window(starts: &[u64], now: u64) -> usize {
    starts.iter().filter(|start| now.saturating_sub(**start) < WINDOW_SECONDS).count()
}

/// Remembers what has been shown, so that each call only returns what is new.
#[derive(Debug, Default)]
pub struct Monitor {
    /// Services whose restart loop has already been told and has not ended since.
    looping: BTreeMap<Service, bool>,
    /// When each notification (by title) was last shown, in seconds since the epoch.
    shown: BTreeMap<String, u64>,
}

impl Monitor {
    /// The notifications for a new reading. `before` is `None` on the first reading after start,
    /// which only records the state: the panel never greets the user with old news.
    pub fn check(&mut self, before: Option<&Overview>, after: &Overview, now: u64) -> Vec<Alert> {
        let mut candidates = before.map(|before| alerts(before, after)).unwrap_or_default();
        for service in Service::ALL {
            // An unreadable journal says nothing; keep the last known state.
            let Some(starts) = service.starts(after) else { continue };
            let count = starts_in_window(starts, now);
            let looping = count > MAX_STARTS;
            let was_looping = self.looping.insert(service, looping).unwrap_or(false);
            if looping && !was_looping && before.is_some() {
                candidates.push(service.alert(count));
            }
        }
        candidates
            .into_iter()
            .filter(|alert| {
                let recent = self.shown.get(&alert.title).is_some_and(|at| now.saturating_sub(*at) < WINDOW_SECONDS);
                if !recent {
                    self.shown.insert(alert.title.clone(), now);
                }
                !recent
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::{PianissimoHealth, RecentStarts, UnitState};

    const NOW: u64 = 1_763_370_000;

    fn running(gateway_starts: Vec<u64>) -> Overview {
        Overview {
            gateway_unit: UnitState::Running,
            transcription_unit: UnitState::Running,
            gateway_health: Some(true),
            pianissimo: Some(PianissimoHealth { status: "ready".into(), ..Default::default() }),
            recent_starts: RecentStarts { gateway: Some(gateway_starts), pianissimo: Some(vec![]) },
            ..Default::default()
        }
    }

    fn titles(alerts: Vec<Alert>) -> Vec<String> {
        alerts.into_iter().map(|alert| alert.title).collect()
    }

    #[test]
    fn more_than_three_starts_in_ten_minutes_is_told_once() {
        let mut monitor = Monitor::default();
        let calm = running(vec![NOW - 3_000]);
        assert!(monitor.check(None, &calm, NOW).is_empty());
        // Three starts in the window is still fine; the fourth makes a loop.
        let three = running(vec![NOW - 500, NOW - 300, NOW - 100]);
        assert!(monitor.check(Some(&calm), &three, NOW).is_empty());
        let four = running(vec![NOW - 500, NOW - 300, NOW - 100, NOW - 5]);
        let alerts = monitor.check(Some(&three), &four, NOW);
        assert_eq!(alerts[0].body, "4 starter på tio minuter. Telefonen får kanske inga AI-svar. Se loggen i Mio Kontroll.");
        assert_eq!(titles(alerts), ["AI-gatewayen startar om gång på gång"]);
        // Still looping a little later: not again.
        let five = running(vec![NOW - 500, NOW - 300, NOW - 100, NOW - 5, NOW + 20]);
        assert!(monitor.check(Some(&four), &five, NOW + 30).is_empty());
        // Starts older than ten minutes no longer count, so the loop has ended ...
        assert!(monitor.check(Some(&five), &five, NOW + 1_000).is_empty());
        // ... and a new loop much later is told again.
        let later = NOW + 2_000;
        let again = running(vec![later - 40, later - 30, later - 20, later - 10]);
        assert_eq!(titles(monitor.check(Some(&five), &again, later)), ["AI-gatewayen startar om gång på gång"]);
    }

    #[test]
    fn an_unreadable_journal_and_the_first_reading_say_nothing() {
        let mut monitor = Monitor::default();
        let looping = running(vec![NOW - 40, NOW - 30, NOW - 20, NOW - 10]);
        // The panel started during a loop: no notification for what was already going on.
        assert!(monitor.check(None, &looping, NOW).is_empty());
        assert!(monitor.check(Some(&looping), &looping, NOW + 5).is_empty());
        let mut unknown = looping.clone();
        unknown.recent_starts = RecentStarts::default();
        let mut fresh = Monitor::default();
        assert!(fresh.check(Some(&running(vec![])), &unknown, NOW).is_empty());
    }

    #[test]
    fn a_service_that_stops_again_and_again_is_told_once_in_ten_minutes() {
        let mut monitor = Monitor::default();
        let up = running(vec![]);
        let mut down = up.clone();
        down.transcription_unit = UnitState::Failed;
        assert!(monitor.check(None, &up, NOW).is_empty());
        assert_eq!(titles(monitor.check(Some(&up), &down, NOW)), ["Pianissimo har stannat"]);
        assert!(monitor.check(Some(&down), &up, NOW + 10).is_empty());
        assert!(monitor.check(Some(&up), &down, NOW + 20).is_empty(), "the same notification within ten minutes");
        assert_eq!(titles(monitor.check(Some(&up), &down, NOW + WINDOW_SECONDS + 20)), ["Pianissimo har stannat"]);
    }

    #[test]
    fn the_window_counts_only_the_last_ten_minutes() {
        assert_eq!(starts_in_window(&[NOW - 600, NOW - 599, NOW], NOW), 2);
        assert_eq!(starts_in_window(&[], NOW), 0);
    }
}
