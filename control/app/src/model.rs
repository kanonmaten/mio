//! The status everything in the app reads: one entity, refreshed in the background.

use std::time::{Duration, Instant};

use gpui_kit::{App, AppContext as _, Context, Entity, EventEmitter, Global};
use mio_control_core::format::now_seconds;
use mio_control_core::probe;
use mio_control_core::status::{Alert, Overview};
use mio_control_core::watch::Monitor;

/// The gateway's port when the helper cannot tell (it is not installed yet).
const DEFAULT_GATEWAY_PORT: u16 = 8_787;
/// How often to read while the window is open, and while only the tray icon runs.
const WINDOW_INTERVAL: Duration = Duration::from_secs(5);
const TRAY_INTERVAL: Duration = Duration::from_secs(30);
/// A check the user asked for spins at least this long, so a fast one is still seen to run.
const MIN_VISIBLE_CHECK: Duration = Duration::from_millis(400);

/// The latest overview and when it was read. Owned by [`ControlState`].
#[derive(Default)]
pub struct StatusModel {
    overview: Overview,
    read_at: Option<Instant>,
    /// Wakes the polling loop; cleared when a reading starts.
    refresh_requested: bool,
    /// From a request until a reading that started after it has been applied: what the
    /// "Kontrollera igen" buttons spin on.
    refreshing: Option<Instant>,
    /// Counts requests; a reading ends the spinning only if no request came after it started.
    requests: u64,
    /// Decides which changes become desktop notifications and keeps them from repeating.
    monitor: Monitor,
}

/// Changes for the worse, for desktop notifications, already filtered for repeats.
pub struct StatusAlerts(pub Vec<Alert>);

impl EventEmitter<StatusAlerts> for StatusModel {}

impl StatusModel {
    pub fn overview(&self) -> &Overview {
        &self.overview
    }

    pub fn has_read(&self) -> bool {
        self.read_at.is_some()
    }

    /// Takes a new reading; notifies observers only when something changed.
    pub fn apply(&mut self, next: Overview, cx: &mut Context<Self>) {
        let before = self.read_at.is_some().then_some(&self.overview);
        let alerts = self.monitor.check(before, &next, now_seconds());
        let first = self.read_at.is_none();
        self.read_at = Some(Instant::now());
        if first || next != self.overview {
            self.overview = next;
            cx.notify();
        }
        if !alerts.is_empty() {
            cx.emit(StatusAlerts(alerts));
        }
    }

    /// Asks the polling loop to read again at once, after the panel changed something.
    pub fn request_refresh(&mut self, cx: &mut Context<Self>) {
        self.refresh_requested = true;
        self.requests += 1;
        if self.refreshing.is_none() {
            self.refreshing = Some(Instant::now());
            cx.notify();
        }
    }

    /// Whether a requested reading is still on its way.
    pub fn refreshing(&self) -> bool {
        self.refreshing.is_some()
    }
}

/// App-wide handles, so the tray and the window share one status.
pub struct ControlState {
    pub status: Entity<StatusModel>,
}

impl Global for ControlState {}

pub fn status(cx: &App) -> Entity<StatusModel> {
    cx.global::<ControlState>().status.clone()
}

/// Creates the status entity and starts reading. Reads block, so they run on the background
/// executor; the entity is only touched on the foreground.
pub fn init(cx: &mut App) -> Entity<StatusModel> {
    let status = cx.new(|_| StatusModel::default());
    cx.set_global(ControlState { status: status.clone() });
    let model = status.clone();
    cx.spawn(async move |cx| {
        loop {
            // A request made while this reading runs leaves `refresh_requested` set, so the next
            // reading starts at once and is the one that ends the spinning.
            let (previous, answers, requests) = model.update(cx, |model, _| {
                model.refresh_requested = false;
                (model.overview.clone(), model.refreshing, model.requests)
            });
            let next = cx.background_executor().spawn(async move { probe::overview(DEFAULT_GATEWAY_PORT, &previous) }).await;
            model.update(cx, |model, cx| model.apply(next, cx));
            if let Some(since) = answers {
                let left = MIN_VISIBLE_CHECK.saturating_sub(since.elapsed());
                if !left.is_zero() {
                    cx.background_executor().timer(left).await;
                }
                model.update(cx, |model, cx| {
                    // A request during this reading is answered by the next one, which starts at once.
                    if model.requests == requests {
                        model.refreshing = None;
                        cx.notify();
                    }
                });
            }
            let interval = if cx.update(|cx| cx.windows().is_empty()) { TRAY_INTERVAL } else { WINDOW_INTERVAL };
            // Sleep in short steps so a requested refresh (after a restart) comes quickly.
            let started = Instant::now();
            while started.elapsed() < interval && !model.read_with(cx, |model, _| model.refresh_requested) {
                cx.background_executor().timer(Duration::from_millis(500)).await;
            }
        }
    })
    .detach();
    status
}
