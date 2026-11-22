//! What the overview and the tray show, read from the services, systemd, Tailscale and the GPU.
//! Parsing is separate from fetching so it is tested without any of them running.

use serde_json::Value;

use crate::backup::BackupStatus;
use crate::format::now_seconds;
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

/// One task in the gateway's `/v2/status`. `reasoning` and `schema_dialect` are `None` when the
/// gateway is older than the post-grilling contract (docs/DATAMODELL.md) and does not send them.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct TaskStatus {
    pub task: String,
    pub provider: String,
    pub model: String,
    /// `"off"` or the reviewed level (`"low"`, `"medium"`, `"high"`).
    pub reasoning: Option<String>,
    /// `"strict-json-schema"` or `"json-schema"`.
    pub schema_dialect: Option<String>,
    /// Whether the task can run: a reviewed pair with its key. `None` from a gateway that does not say.
    pub configured: Option<bool>,
}

impl TaskStatus {
    pub fn new(task: &str, provider: &str, model: &str) -> Self {
        Self { task: task.to_owned(), provider: provider.to_owned(), model: model.to_owned(), ..Self::default() }
    }

    /// "Resonerar inte", "Resonerar (hög)", or `None` when the gateway does not say.
    pub fn reasoning_label(&self) -> Option<String> {
        self.reasoning.as_deref().map(reasoning_label)
    }
}

/// The Swedish words for a reasoning setting from the gateway.
pub fn reasoning_label(reasoning: &str) -> String {
    match reasoning {
        "off" => "Resonerar inte".to_owned(),
        "low" => "Resonerar (låg)".to_owned(),
        "medium" => "Resonerar (medel)".to_owned(),
        "high" => "Resonerar (hög)".to_owned(),
        other => format!("Resonerar ({other})"),
    }
}

/// One task, provider and model used this month, from `usage.entries`.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct UsageEntry {
    pub task: String,
    pub provider: String,
    pub model: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    /// In `Usage::currency`; `None` for a model without a reviewed price (Groq's free tier).
    pub estimated_cost: Option<f64>,
    pub prices_as_of: Option<String>,
}

/// The gateway's token and cost counters for the current UTC month (`usage` in `/v2/status`).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Usage {
    pub month: String,
    pub currency: String,
    /// The sum of the entries that have a price.
    pub estimated_cost: f64,
    pub entries: Vec<UsageEntry>,
}

impl Usage {
    /// `None` for `null` (an unknown counter file on the gateway) or anything malformed.
    pub fn parse(body: &Value) -> Option<Self> {
        let number = |value: &Value, name: &str| value.get(name).and_then(Value::as_u64).unwrap_or(0);
        let text = |value: &Value, name: &str| value.get(name).and_then(Value::as_str).map(str::to_owned);
        let entries = body
            .get("entries")?
            .as_array()?
            .iter()
            .filter_map(|entry| {
                Some(UsageEntry {
                    task: text(entry, "task")?,
                    provider: text(entry, "provider")?,
                    model: text(entry, "model")?,
                    requests: number(entry, "requests"),
                    input_tokens: number(entry, "inputTokens"),
                    cached_input_tokens: number(entry, "cachedInputTokens"),
                    output_tokens: number(entry, "outputTokens"),
                    reasoning_tokens: number(entry, "reasoningTokens"),
                    estimated_cost: entry.get("estimatedCost").and_then(Value::as_f64).filter(|cost| cost.is_finite() && *cost >= 0.0),
                    prices_as_of: text(entry, "pricesAsOf"),
                })
            })
            .collect::<Vec<_>>();
        let summed: f64 = entries.iter().filter_map(|entry| entry.estimated_cost).sum();
        Some(Self {
            month: text(body, "month")?,
            currency: text(body, "currency").unwrap_or_else(|| "USD".to_owned()),
            estimated_cost: body.get("estimatedCost").and_then(Value::as_f64).filter(|cost| cost.is_finite() && *cost >= 0.0).unwrap_or(summed),
            entries,
        })
    }
}

/// The parts of the gateway's `/v2/status` the panel shows. Nothing in it is secret.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct GatewayStatus {
    pub revision: Option<String>,
    /// `(limit, remaining, unit)` of the daily quota, when there is one.
    pub quota: Option<(u64, u64, String)>,
    pub quota_reset: Option<String>,
    pub tasks: Vec<TaskStatus>,
    /// `None` from a gateway without the counters, or when it answers `usage: null`.
    pub usage: Option<Usage>,
    /// `None` from a gateway without backups (or a malformed field): the panel then shows nothing.
    pub backup: Option<BackupStatus>,
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
                        let field = |name: &str| value.get(name).and_then(Value::as_str).map(str::to_owned);
                        TaskStatus {
                            task: task.clone(),
                            provider: field("provider").unwrap_or_default(),
                            model: field("model").unwrap_or_default(),
                            reasoning: field("reasoning"),
                            schema_dialect: field("schemaDialect"),
                            configured: value.get("configured").and_then(Value::as_bool),
                        }
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
            usage: body.get("usage").and_then(Usage::parse),
            backup: body.get("backup").and_then(BackupStatus::parse),
        }
    }

    pub fn task(&self, task: &str) -> Option<&TaskStatus> {
        self.tasks.iter().find(|status| status.task == task)
    }

    /// Less than a tenth of the day's quota left.
    pub fn quota_is_low(&self) -> bool {
        self.quota.as_ref().is_some_and(|(limit, remaining, _)| *limit > 0 && remaining * 10 < *limit)
    }

    /// The newest nightly backup is more than 48 hours old.
    pub fn backup_is_stale(&self, now_seconds: u64) -> bool {
        self.backup.as_ref().is_some_and(|backup| backup.is_stale(now_seconds))
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
        // Since driver 620 the temperature comes with decimals ("45.37"); any field may, so every
        // number is read as a decimal and rounded. A failed parse here reads as "no GPU".
        let number = |text: &str| text.parse::<f64>().ok().filter(|value| value.is_finite() && *value >= 0.0).map(|value| value.round() as u64);
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
    /// When each service was started in the last ten minutes, from the journal.
    pub recent_starts: RecentStarts,
}

/// Start times (seconds since the epoch) of the two services in the last ten minutes, read from
/// systemd's "Starting …" journal entries. `None` when the journal could not be read (the user is
/// not in `systemd-journal`), so the restart watch stays quiet instead of guessing.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct RecentStarts {
    pub gateway: Option<Vec<u64>>,
    pub pianissimo: Option<Vec<u64>>,
}

impl Overview {
    /// The tray dot now; see [`Overview::tray_status_at`].
    pub fn tray_status(&self) -> Option<TrayStatus> {
        self.tray_status_at(now_seconds())
    }

    /// The tray dot: red when an installed service is down, amber while something loads, the
    /// quota runs low or the nightly backup is older than 48 hours, green when everything runs.
    /// `None` before anything is known. An old backup never makes it red.
    pub fn tray_status_at(&self, now_seconds: u64) -> Option<TrayStatus> {
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
            || self.gateway.as_ref().is_some_and(GatewayStatus::quota_is_low)
            || self.gateway.as_ref().is_some_and(|gateway| gateway.backup_is_stale(now_seconds));
        Some(if busy { TrayStatus::Warning } else { TrayStatus::Ok })
    }

    /// The tray tooltip now; see [`Overview::summary_at`].
    pub fn summary(&self) -> String {
        self.summary_at(now_seconds())
    }

    /// The tray tooltip, one part per service: "Gateway kör · Pianissimo redo · Tailscale ok".
    pub fn summary_at(&self, now_seconds: u64) -> String {
        let gateway = match (&self.gateway_unit, self.gateway_health) {
            (UnitState::Running, Some(false)) => "Gateway svarar inte".to_owned(),
            (UnitState::Running, _) if self.gateway.as_ref().is_some_and(GatewayStatus::quota_is_low) => "Gateway kör, kvoten nästan slut".to_owned(),
            (UnitState::Running, _) if self.gateway.as_ref().is_some_and(|gateway| gateway.backup_is_stale(now_seconds)) => {
                "Gateway kör, säkerhetskopian är gammal".to_owned()
            }
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
        // Driver 620.73.04 on the PC, 2026-11-22.
        let gpu = GpuStatus::parse("NVIDIA GeForce RTX 4060 Ti, 937, 8188, 45.37, 13\n").unwrap();
        assert_eq!((gpu.memory_used_mib, gpu.temperature_c, gpu.utilization_percent), (937, 45, 13));
        assert_eq!(GpuStatus::parse("GPU, 1, 2, -1, 3"), None);
    }

    #[test]
    fn gateway_status_quota_and_tasks() {
        let body = json!({"configurationRevision": "r1", "quota": {"limit": 190000, "remaining": 9000, "resetAt": "2026-11-18T00:00:00Z", "unit": "tokens"},
            "tasks": {"ask": {"provider": "groq", "model": "qwen/qwen3.8-27b"}}});
        let status = GatewayStatus::parse(&body);
        assert!(status.quota_is_low());
        assert_eq!(status.tasks, [TaskStatus::new("ask", "groq", "qwen/qwen3.8-27b")]);
        // A gateway older than the post-grilling contract: no reasoning, dialect or usage.
        assert_eq!((status.tasks[0].reasoning_label(), status.usage.as_ref()), (None, None));
        assert!(!GatewayStatus::parse(&json!({"quota": null})).quota_is_low());
        assert_eq!(status.backup, None, "a gateway without backups sends no field");
    }

    #[test]
    fn the_backup_field_is_read_and_an_old_copy_turns_the_dot_amber_not_red() {
        // 2026-11-20 03:12:00 UTC, made-up values in the shape of the contract.
        let night = 1_795_144_320;
        let body = json!({"backup": {"latestAt": "2026-11-20T03:12:00Z", "count": 3, "bytes": 4_200_000}});
        let gateway = GatewayStatus::parse(&body);
        assert_eq!(gateway.backup, Some(BackupStatus { latest_at: Some(night), count: 3, bytes: 4_200_000 }));
        let mut overview = healthy();
        overview.gateway = Some(gateway);
        let fresh = night + 47 * 3_600;
        let old = night + 49 * 3_600;
        assert_eq!((overview.tray_status_at(fresh), overview.summary_at(fresh).as_str()), (Some(TrayStatus::Ok), "Gateway kör · Pianissimo redo · Tailscale ok"));
        assert_eq!(overview.tray_status_at(old), Some(TrayStatus::Warning));
        assert_eq!(overview.summary_at(old), "Gateway kör, säkerhetskopian är gammal · Pianissimo redo · Tailscale ok");
        // Still red when a service is down, never redder because of the copy.
        overview.transcription_unit = UnitState::Failed;
        assert_eq!(overview.tray_status_at(old), Some(TrayStatus::Error));
        // No copy yet is not a warning.
        let none = GatewayStatus::parse(&json!({"backup": {"latestAt": null, "count": 0, "bytes": 0}}));
        assert!(none.backup.is_some() && !none.backup_is_stale(old));
    }

    #[test]
    fn reasoning_dialect_and_usage_follow_the_contract() {
        // Made-up values in the shape of docs/DATAMODELL.md, "Kontrakt efter grillningen".
        let body = json!({"tasks": {
                "ask": {"provider": "mistral", "model": "small", "reasoning": "off", "schemaDialect": "strict-json-schema"},
                "lesson": {"provider": "mistral", "model": "large", "reasoning": "high", "schemaDialect": "json-schema"}},
            "usage": {"month": "2026-11", "currency": "USD", "estimatedCost": 3.42, "entries": [
                {"task": "ask", "provider": "groq", "model": "qwen", "requests": 4, "inputTokens": 900, "cachedInputTokens": 0,
                 "outputTokens": 100, "reasoningTokens": 0, "estimatedCost": null, "pricesAsOf": null},
                {"task": "lesson", "provider": "mistral", "model": "large", "requests": 12, "inputTokens": 40000, "cachedInputTokens": 0,
                 "outputTokens": 21000, "reasoningTokens": 9000, "estimatedCost": 0.0721, "pricesAsOf": "2026-11-20"},
                {"task": "broken"}]}});
        let status = GatewayStatus::parse(&body);
        let lesson = status.task("lesson").unwrap();
        assert_eq!((lesson.reasoning_label().as_deref(), lesson.schema_dialect.as_deref()), (Some("Resonerar (hög)"), Some("json-schema")));
        assert_eq!(status.task("ask").unwrap().reasoning_label().as_deref(), Some("Resonerar inte"));
        let usage = status.usage.unwrap();
        assert_eq!((usage.month.as_str(), usage.estimated_cost, usage.entries.len()), ("2026-11", 3.42, 2));
        assert_eq!((usage.entries[0].estimated_cost, usage.entries[1].estimated_cost, usage.entries[1].reasoning_tokens), (None, Some(0.0721), 9000));
        // `usage: null` (an unknown counter file) and a missing total.
        assert_eq!(GatewayStatus::parse(&json!({"usage": null})).usage, None);
        let summed = Usage::parse(&json!({"month": "2026-11", "entries": [{"task": "ask", "provider": "p", "model": "m", "estimatedCost": 0.5}]})).unwrap();
        assert_eq!((summed.estimated_cost, summed.currency.as_str()), (0.5, "USD"));
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
            recent_starts: RecentStarts::default(),
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
