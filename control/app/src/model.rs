//! The status everything in the app reads: one entity, refreshed in the background.

use std::time::{Duration, Instant};

use gpui_kit::{App, AppContext as _, Context, Entity, EventEmitter, Global};
use mio_control_core::probe;
use mio_control_core::status::{Alert, Overview, alerts};

/// The gateway's port when the helper cannot tell (it is not installed yet).
const DEFAULT_GATEWAY_PORT: u16 = 8_787;
/// How often to read while the window is open, and while only the tray icon runs.
const WINDOW_INTERVAL: Duration = Duration::from_secs(5);
const TRAY_INTERVAL: Duration = Duration::from_secs(30);

/// The latest overview and when it was read. Owned by [`ControlState`].
#[derive(Default)]
pub struct StatusModel {
    overview: Overview,
    read_at: Option<Instant>,
    refresh_requested: bool,
}

/// Changes for the worse, for desktop notifications.
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
        let alerts = if self.read_at.is_some() { alerts(&self.overview, &next) } else { Vec::new() };
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
    pub fn request_refresh(&mut self) {
        self.refresh_requested = true;
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
            let previous = model.read_with(cx, |model, _| model.overview.clone());
            let next = cx.background_executor().spawn(async move { probe::overview(DEFAULT_GATEWAY_PORT, &previous) }).await;
            model.update(cx, |model, cx| {
                model.refresh_requested = false;
                model.apply(next, cx);
            });
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
