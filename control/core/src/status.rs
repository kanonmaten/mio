//! What the overview and the tray show, read from the services, systemd, Tailscale and the GPU.
//! Parsing is separate from fetching so it is tested without any of them running.

use serde_json::Value;

use crate::tray_icon::TrayStatus;

/// A systemd unit as the panel describes it.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum UnitState {
    /// Not read yet.
    #[default]
    Unknown,
    /// The unit file does not exist: the service is not installed.
    NotInstalled,
    Running,
    Starting,
    Stopping,
    Stopped,
    Failed,
}

impl UnitState {
    /// From systemd's `LoadState`, `ActiveState` and `SubState`.
    pub fn from_systemd(load: &str, active: &str, sub: &str) -> Self {
        if load == "not-found" {
            return UnitState::NotInstalled;
        }
        match active {
            "active" | "reloading" => UnitState::Running,
            "activating" if sub == "auto-restart" => UnitState::Failed,
            "activating" => UnitState::Starting,
            "deactivating" => UnitState::Stopping,
            "failed" => UnitState::Failed,
            "inactive" => UnitState::Stopped,
            _ => UnitState::Unknown,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            UnitState::Unknown => "Läser …",
            UnitState::NotInstalled => "Inte installerad",
            UnitState::Running => "Kör",
            UnitState::Starting => "Startar",
            UnitState::Stopping => "Stoppar",
            UnitState::Stopped => "Stoppad",
            UnitState::Failed => "Har kraschat",
        }
    }
}

/// The nightly update timer and its last run.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct TimerStatus {
    pub enabled: bool,
    /// Microseconds since the epoch of the last run; `None` if it never ran.
    pub last_run_usec: Option<u64>,
    /// `success`, `exit-code`, … from the update service's `Result`.
    pub last_result: Option<String>,
}

/// Pianissimo's `/health`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PianissimoHealth {
    /// `ready`, `loading` or `failed`.
    pub status: String,
    pub model: Option<String>,
    pub revision: Option<String>,
    pub precision: Option<String>,
    pub speaker_labels: Option<String>,
    pub preprocessing: Option<bool>,
    pub vocabulary: Option<u64>,
}

impl PianissimoHealth {
    pub fn parse(body: &Value) -> Option<Self> {
        let text = |value: &Value| value.as_str().map(str::to_owned);
        Some(Self {
            status: text(body.get("status")?)?,
            model: body.pointer("/metadata/model").and_then(text),
            revision: body.pointer("/metadata/revision").and_then(text),
            precision: body.get("precision").and_then(text),
            speaker_labels: body.get("speakerLabels").and_then(text),
            preprocessing: body.get("preprocessing").and_then(Value::as_bool),
            vocabulary: body.get("vocabulary").and_then(Value::as_u64),
        })
    }

    pub fn is_ready(&self) -> bool {
        self.status == "ready"
    }
}

/// The parts of the gateway's `/v2/status` the panel shows. Nothing in it is secret.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct GatewayStatus {
    pub revision: Option<String>,
    /// `(limit, remaining, unit)` of the daily quota, when there is one.
    pub quota: Option<(u64, u64, String)>,
    pub quota_reset: Option<String>,
    pub tasks: Vec<(String, String, String)>,
}

impl GatewayStatus {
    pub fn parse(body: &Value) -> Self {
        let quota = body.get("quota").filter(|quota| quota.is_object());
        let tasks = body
            .get("tasks")
            .and_then(Value::as_object)
            .map(|tasks| {
                tasks
                    .iter()
                    .map(|(task, value)| {
                        let field = |name: &str| value.get(name).and_then(Value::as_str).unwrap_or("").to_owned();
                        (task.clone(), field("provider"), field("model"))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            revision: body.get("configurationRevision").and_then(Value::as_str).map(str::to_owned),
            quota: quota.and_then(|quota| {
                Some((quota.get("limit")?.as_u64()?, quota.get("remaining")?.as_u64()?, quota.get("unit")?.as_str()?.to_owned()))
            }),
            quota_reset: quota.and_then(|quota| quota.get("resetAt")).and_then(Value::as_str).map(str::to_owned),
            tasks,
        }
    }

    /// Less than a tenth of the day's quota left.
    pub fn quota_is_low(&self) -> bool {
        self.quota.as_ref().is_some_and(|(limit, remaining, _)| *limit > 0 && remaining * 10 < *limit)
    }
}

/// Tailscale on this computer, from `tailscale status --json` and `tailscale serve status --json`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct TailscaleStatus {
    pub installed: bool,
    pub logged_in: bool,
    /// The MagicDNS name without the trailing dot.
    pub host: Option<String>,
    pub address: Option<String>,
    /// Where HTTPS 443 and 8443 are proxied to.
    pub serve_443: Option<String>,
    pub serve_8443: Option<String>,
    /// Funnel makes a port public on the internet; Mio never wants it.
    pub funnel: bool,
}

impl TailscaleStatus {
    pub fn parse(status: &Value, serve: &Value) -> Self {
        let own = status.get("Self");
        let host = own
            .and_then(|own| own.get("DNSName"))
            .and_then(Value::as_str)
            .map(|name| name.trim_end_matches('.').to_owned())
            .filter(|name| !name.is_empty());
        let target = |port: u16| {
            serve.get("Web").and_then(Value::as_object)?.iter().find_map(|(host_port, web)| {
                let listens = host_port.rsplit_once(':').and_then(|(_, number)| number.parse::<u16>().ok()) == Some(port);
                listens.then(|| web.pointer("/Handlers/~1/Proxy").and_then(Value::as_str).map(str::to_owned)).flatten()
            })
        };
        Self {
            installed: true,
            logged_in: status.get("BackendState").and_then(Value::as_str) == Some("Running"),
            host,
            address: own
                .and_then(|own| own.get("TailscaleIPs"))
                .and_then(Value::as_array)
                .and_then(|addresses| addresses.first())
                .and_then(Value::as_str)
                .map(str::to_owned),
            serve_443: target(443),
            serve_8443: target(8443),
            funnel: serve.get("AllowFunnel").and_then(Value::as_object).is_some_and(|funnel| funnel.values().any(|on| on.as_bool() == Some(true))),
        }
    }

    /// `serve` points at Pianissimo on 443 and the gateway on 8443, as the installers set it up.
    pub fn serve_is_correct(&self, gateway_port: u16) -> bool {
        self.serve_443.as_deref() == Some("http://127.0.0.1:8765")
            && self.serve_8443.as_deref() == Some(format!("http://127.0.0.1:{gateway_port}").as_str())
    }
}

/// The first GPU from `nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader,nounits`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct GpuStatus {
    pub name: String,
    pub memory_used_mib: u64,
    pub memory_total_mib: u64,
    pub temperature_c: u64,
    pub utilization_percent: u64,
}

pub const NVIDIA_SMI_QUERY: &str = "--query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu";

impl GpuStatus {
    pub fn parse(csv: &str) -> Option<Self> {
        let line = csv.lines().find(|line| !line.trim().is_empty())?;
        let fields: Vec<&str> = line.split(',').map(str::trim).collect();
        let [name, used, total, temperature, utilization] = fields.as_slice() else { return None };
        let number = |text: &str| text.parse::<u64>().ok();
        Some(Self {
            name: (*name).to_owned(),
            memory_used_mib: number(used)?,
            memory_total_mib: number(total)?,
            temperature_c: number(temperature)?,
            utilization_percent: number(utilization).unwrap_or(0),
        })
    }
}

/// Everything the overview shows. Each part is `None` until it has been read once.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Overview {
    pub gateway_unit: UnitState,
    pub transcription_unit: UnitState,
    /// Whether `GET /health` on the gateway answered `ok`.
    pub gateway_health: Option<bool>,
    pub gateway: Option<GatewayStatus>,
    pub pianissimo: Option<PianissimoHealth>,
    pub tailscale: Option<TailscaleStatus>,
    pub gpu: Option<GpuStatus>,
    pub update_timer: Option<TimerStatus>,
}

impl Overview {
    /// The tray dot: red when an installed service is down, amber while something loads or the
    /// quota runs low, green when everything runs. `None` before anything is known.
    pub fn tray_status(&self) -> Option<TrayStatus> {
        let units = [&self.gateway_unit, &self.transcription_unit];
        if units.iter().all(|unit| **unit == UnitState::Unknown) {
            return None;
        }
        let down = units.iter().any(|unit| matches!(unit, UnitState::Stopped | UnitState::Failed))
            || self.gateway_health == Some(false) && self.gateway_unit == UnitState::Running
            || self.pianissimo.as_ref().is_some_and(|health| health.status == "failed")
            || self.tailscale.as_ref().is_some_and(|tailscale| !tailscale.logged_in);
        if down {
            return Some(TrayStatus::Error);
        }
        let busy = units.iter().any(|unit| matches!(unit, UnitState::Starting | UnitState::Stopping | UnitState::NotInstalled | UnitState::Unknown))
            || self.pianissimo.as_ref().is_some_and(|health| !health.is_ready())
            || self.gateway.as_ref().is_some_and(GatewayStatus::quota_is_low);
        Some(if busy { TrayStatus::Warning } else { TrayStatus::Ok })
    }

    /// The tray tooltip, one part per service: "Gateway kör · Pianissimo redo · Tailscale ok".
    pub fn summary(&self) -> String {
        let gateway = match (&self.gateway_unit, self.gateway_health) {
            (UnitState::Running, Some(false)) => "Gateway svarar inte".to_owned(),
            (UnitState::Running, _) if self.gateway.as_ref().is_some_and(GatewayStatus::quota_is_low) => "Gateway kör, kvoten nästan slut".to_owned(),
            (state, _) => format!("Gateway {}", state.label().to_lowercase()),
        };
        let pianissimo = match (&self.transcription_unit, &self.pianissimo) {
            (UnitState::Running, Some(health)) if health.is_ready() => "Pianissimo redo".to_owned(),
            (UnitState::Running, Some(health)) if health.status == "failed" => "Pianissimo fel".to_owned(),
            (UnitState::Running, _) => "Pianissimo laddar".to_owned(),
            (state, _) => format!("Pianissimo {}", state.label().to_lowercase()),
        };
        let tailscale = match &self.tailscale {
            None => "Tailscale läser …",
            Some(status) if !status.installed => "Tailscale saknas",
            Some(status) if !status.logged_in => "Tailscale utloggad",
            Some(_) => "Tailscale ok",
        };
        format!("{gateway} · {pianissimo} · {tailscale}")
    }
}

/// A desktop notification for a change the user should hear about even with the window closed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Alert {
    pub title: String,
    pub body: String,
}

/// What changed for the worse between two reads: a service went down, Pianissimo failed, the
/// nightly update failed or the day's AI quota ran out. Nothing on the first read.
pub fn alerts(before: &Overview, after: &Overview) -> Vec<Alert> {
    let mut alerts = Vec::new();
    let alert = |title: &str, body: &str| Alert { title: title.to_owned(), body: body.to_owned() };
    let went_down = |before: &UnitState, after: &UnitState| {
        matches!(before, UnitState::Running | UnitState::Starting) && matches!(after, UnitState::Stopped | UnitState::Failed)
    };
    if went_down(&before.gateway_unit, &after.gateway_unit) {
        alerts.push(alert("AI-gatewayen har stannat", "Telefonen får inga AI-svar. Öppna Mio Kontroll för att starta den igen."));
    }
    if went_down(&before.transcription_unit, &after.transcription_unit) {
        alerts.push(alert("Pianissimo har stannat", "Telefonen får ingen text. Öppna Mio Kontroll för att starta den igen."));
    }
    let failed = |overview: &Overview| overview.pianissimo.as_ref().is_some_and(|health| health.status == "failed");
    if !failed(before) && failed(after) && after.transcription_unit == UnitState::Running {
        alerts.push(alert("Pianissimo fungerar inte", "Modellen kunde inte laddas. Se loggen i Mio Kontroll."));
    }
    if let (Some(earlier), Some(later)) = (&before.update_timer, &after.update_timer)
        && later.last_run_usec.is_some()
        && later.last_run_usec != earlier.last_run_usec
        && later.last_result.as_deref().is_some_and(|result| result != "success")
    {
        alerts.push(alert("Nattuppdateringen misslyckades", "Pianissimo kör vidare med den förra versionen."));
    }
    let remaining = |overview: &Overview| overview.gateway.as_ref().and_then(|gateway| gateway.quota.as_ref()).map(|quota| quota.1);
    if remaining(before).is_some_and(|left| left > 0) && remaining(after) == Some(0) {
        alerts.push(alert("Dagens AI-kvot är slut", "AI fungerar igen när kvoten nollställs vid midnatt (UTC)."));
    }
    alerts
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn systemd_states_map_to_what_the_panel_says() {
        assert_eq!(UnitState::from_systemd("loaded", "active", "running"), UnitState::Running);
        assert_eq!(UnitState::from_systemd("loaded", "activating", "start"), UnitState::Starting);
        // A crash loop shows as activating/auto-restart; that is a failure, not a start.
        assert_eq!(UnitState::from_systemd("loaded", "activating", "auto-restart"), UnitState::Failed);
        assert_eq!(UnitState::from_systemd("loaded", "inactive", "dead"), UnitState::Stopped);
        assert_eq!(UnitState::from_systemd("not-found", "inactive", "dead"), UnitState::NotInstalled);
    }

    #[test]
    fn pianissimo_health_is_read_from_its_documented_answer() {
        let body = json!({"apiVersion": 1, "status": "ready", "metadata": {"model": "KlangAI/pianissimo-sv", "revision": "abc"},
            "preprocessing": true, "speakerLabels": "ready", "vocabulary": 12, "precision": "fp16"});
        let health = PianissimoHealth::parse(&body).unwrap();
        assert!(health.is_ready());
        assert_eq!((health.vocabulary, health.precision.as_deref(), health.revision.as_deref()), (Some(12), Some("fp16"), Some("abc")));
        assert_eq!(PianissimoHealth::parse(&json!({"detail": "unauthorized"})), None);
    }

    #[test]
    fn tailscale_status_and_serve_are_read_and_funnel_is_noticed() {
        let status = json!({"BackendState": "Running", "Self": {"DNSName": "dator.tail1234.ts.net.", "TailscaleIPs": ["100.64.0.1", "fd7a::1"]}});
        let serve = json!({"TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true}},
            "Web": {"dator.tail1234.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8765"}}},
                    "dator.tail1234.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8787"}}}}});
        let tailscale = TailscaleStatus::parse(&status, &serve);
        assert_eq!((tailscale.host.as_deref(), tailscale.address.as_deref()), (Some("dator.tail1234.ts.net"), Some("100.64.0.1")));
        assert!(tailscale.logged_in && tailscale.serve_is_correct(8787) && !tailscale.funnel);
        let public = json!({"AllowFunnel": {"dator.tail1234.ts.net:443": true}});
        let tailscale = TailscaleStatus::parse(&json!({"BackendState": "NeedsLogin"}), &public);
        assert!(tailscale.funnel && !tailscale.logged_in && !tailscale.serve_is_correct(8787));
    }

    #[test]
    fn gpu_line_from_nvidia_smi() {
        let gpu = GpuStatus::parse("NVIDIA GeForce RTX 4060 Ti, 5321, 8188, 54, 37\n").unwrap();
        assert_eq!((gpu.memory_used_mib, gpu.memory_total_mib, gpu.temperature_c, gpu.utilization_percent), (5321, 8188, 54, 37));
        assert_eq!(GpuStatus::parse("NVIDIA-SMI has failed"), None);
    }

    #[test]
    fn gateway_status_quota_and_tasks() {
        let body = json!({"configurationRevision": "r1", "quota": {"limit": 190000, "remaining": 9000, "resetAt": "2026-11-18T00:00:00Z", "unit": "tokens"},
            "tasks": {"ask": {"provider": "groq", "model": "qwen/qwen3.8-27b"}}});
        let status = GatewayStatus::parse(&body);
        assert!(status.quota_is_low());
        assert_eq!(status.tasks, [("ask".to_owned(), "groq".to_owned(), "qwen/qwen3.8-27b".to_owned())]);
        assert!(!GatewayStatus::parse(&json!({"quota": null})).quota_is_low());
    }

    fn healthy() -> Overview {
        Overview {
            gateway_unit: UnitState::Running,
            transcription_unit: UnitState::Running,
            gateway_health: Some(true),
            gateway: Some(GatewayStatus::default()),
            pianissimo: Some(PianissimoHealth { status: "ready".into(), ..Default::default() }),
            tailscale: Some(TailscaleStatus { installed: true, logged_in: true, ..Default::default() }),
            gpu: None,
            update_timer: None,
        }
    }

    #[test]
    fn the_tray_dot_and_tooltip_follow_the_services() {
        assert_eq!(Overview::default().tray_status(), None);
        let mut overview = healthy();
        assert_eq!(overview.tray_status(), Some(TrayStatus::Ok));
        assert_eq!(overview.summary(), "Gateway kör · Pianissimo redo · Tailscale ok");
        overview.pianissimo = Some(PianissimoHealth { status: "loading".into(), ..Default::default() });
        assert_eq!(overview.tray_status(), Some(TrayStatus::Warning));
        assert_eq!(overview.summary(), "Gateway kör · Pianissimo laddar · Tailscale ok");
        overview.transcription_unit = UnitState::Stopped;
        assert_eq!(overview.tray_status(), Some(TrayStatus::Error));
        assert_eq!(overview.summary(), "Gateway kör · Pianissimo stoppad · Tailscale ok");
    }

    #[test]
    fn alerts_only_for_changes_for_the_worse() {
        let before = healthy();
        assert!(alerts(&Overview::default(), &before).is_empty(), "the first read never alerts");
        assert!(alerts(&before, &before).is_empty());
        let mut after = before.clone();
        after.transcription_unit = UnitState::Failed;
        let titles: Vec<String> = alerts(&before, &after).into_iter().map(|alert| alert.title).collect();
        assert_eq!(titles, ["Pianissimo har stannat"]);
        // Back up again is no alert; neither is a service that was already down.
        assert!(alerts(&after, &before).is_empty());
        assert!(alerts(&after, &after).is_empty());
        let mut quota = before.clone();
        quota.gateway = Some(GatewayStatus { quota: Some((100, 5, "tokens".into())), ..Default::default() });
        let mut spent = quota.clone();
        spent.gateway = Some(GatewayStatus { quota: Some((100, 0, "tokens".into())), ..Default::default() });
        assert_eq!(alerts(&quota, &spent)[0].title, "Dagens AI-kvot är slut");
        let mut night = before.clone();
        night.update_timer = Some(TimerStatus { enabled: true, last_run_usec: Some(1), last_result: Some("success".into()) });
        let mut failed_night = night.clone();
        failed_night.update_timer = Some(TimerStatus { enabled: true, last_run_usec: Some(2), last_result: Some("exit-code".into()) });
        assert_eq!(alerts(&night, &failed_night)[0].title, "Nattuppdateringen misslyckades");
    }
}
