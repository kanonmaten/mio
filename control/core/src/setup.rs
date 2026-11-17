//! Kom igång: the steps that set up Mio on a new computer, and which are already done according
//! to the status. A step that is done is skipped, but can always be run again.

use crate::status::{Overview, UnitState};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// NVIDIA driver, Rust and Tailscale.
    Tools,
    Gateway,
    Pianissimo,
    Serve,
    Pair,
}

impl Step {
    pub const ALL: [Step; 5] = [Step::Tools, Step::Gateway, Step::Pianissimo, Step::Serve, Step::Pair];

    pub fn title(self) -> &'static str {
        match self {
            Step::Tools => "Drivrutin och verktyg",
            Step::Gateway => "AI-gatewayen",
            Step::Pianissimo => "Pianissimo",
            Step::Serve => "Tailscale serve",
            Step::Pair => "Para telefonen",
        }
    }

    /// Whether the status shows the step as done. Pairing can't be seen from the computer.
    pub fn done(self, overview: &Overview, gateway_port: u16) -> bool {
        let tailscale = overview.tailscale.as_ref();
        match self {
            Step::Tools => overview.gpu.is_some() && tailscale.is_some_and(|tailscale| tailscale.logged_in),
            Step::Gateway => !matches!(overview.gateway_unit, UnitState::NotInstalled | UnitState::Unknown) && overview.gateway_health == Some(true),
            Step::Pianissimo => overview.pianissimo.as_ref().is_some_and(|health| health.status == "ready"),
            Step::Serve => tailscale.is_some_and(|tailscale| tailscale.serve_is_correct(gateway_port)),
            Step::Pair => false,
        }
    }
}

/// The first step not yet done.
pub fn current(overview: &Overview, gateway_port: u16) -> Step {
    Step::ALL.into_iter().find(|step| !step.done(overview, gateway_port)).unwrap_or(Step::Pair)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::{GpuStatus, PianissimoHealth, TailscaleStatus};

    #[test]
    fn the_guide_starts_at_the_first_step_not_done() {
        let mut overview = Overview::default();
        assert_eq!(current(&overview, 8_787), Step::Tools);
        overview.gpu = Some(GpuStatus::default());
        overview.tailscale = Some(TailscaleStatus { installed: true, logged_in: true, ..Default::default() });
        assert_eq!(current(&overview, 8_787), Step::Gateway);
        overview.gateway_unit = UnitState::Running;
        overview.gateway_health = Some(true);
        overview.pianissimo = Some(PianissimoHealth { status: "loading".into(), ..Default::default() });
        assert_eq!(current(&overview, 8_787), Step::Pianissimo);
        overview.pianissimo = Some(PianissimoHealth { status: "ready".into(), ..Default::default() });
        assert_eq!(current(&overview, 8_787), Step::Serve);
        let tailscale = overview.tailscale.as_mut().unwrap();
        tailscale.serve_443 = Some("http://127.0.0.1:8765".into());
        tailscale.serve_8443 = Some("http://127.0.0.1:8787".into());
        assert_eq!(current(&overview, 8_787), Step::Pair);
    }
}
