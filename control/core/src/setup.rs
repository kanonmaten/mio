//! Kom igång: the steps that set up Mio on a new computer, and which are already done according
//! to the status. A step that is done is skipped, but can always be run again.

use crate::status::{Overview, UnitState};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// NVIDIA driver, Rust and Tailscale.
    Tools,
    Gateway,
    /// Provider, key and model per task, chosen in the panel.
    Ai,
    Pianissimo,
    Serve,
    Pair,
}

impl Step {
    pub const ALL: [Step; 6] = [Step::Tools, Step::Gateway, Step::Ai, Step::Pianissimo, Step::Serve, Step::Pair];

    pub fn title(self) -> &'static str {
        match self {
            Step::Tools => "Drivrutin och verktyg",
            Step::Gateway => "AI-gatewayen",
            Step::Ai => "AI-leverantör",
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
            // Every task runs: the gateway says so per task once a key and a reviewed model are set.
            Step::Ai => overview.gateway.as_ref().is_some_and(|gateway| {
                crate::ai_settings::TASKS.iter().all(|(task, _)| gateway.tasks.iter().any(|status| status.task == *task && status.configured == Some(true)))
            }),
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
        // Installed without a key: the AI step is next until every task runs.
        assert_eq!(current(&overview, 8_787), Step::Ai);
        let mut gateway = crate::status::GatewayStatus::parse(&serde_json::json!({ "tasks": {
            "ask": { "provider": "mistral", "model": "m", "configured": true },
            "everyday": { "provider": "mistral", "model": "m", "configured": true },
            "lesson": { "provider": "mistral", "model": "m", "configured": false } } }));
        overview.gateway = Some(gateway.clone());
        assert_eq!(current(&overview, 8_787), Step::Ai);
        gateway.tasks.iter_mut().for_each(|task| task.configured = Some(true));
        overview.gateway = Some(gateway);
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
