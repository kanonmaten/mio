//! UI integration tests: the real shell and overview in a headless window, fed fake status.

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::model::StatusModel;
use mio_control::shell::{Page, Shell};
use mio_control_core::backup::BackupStatus;
use mio_control_core::format::now_seconds;
use mio_control_core::status::{GatewayStatus, Overview, PianissimoHealth, TailscaleStatus, TaskStatus, UnitState};

fn healthy() -> Overview {
    Overview {
        gateway_unit: UnitState::Running,
        transcription_unit: UnitState::Running,
        gateway_health: Some(true),
        gateway: Some(GatewayStatus {
            quota: Some((190_000, 150_000, "tokens".into())),
            tasks: vec![TaskStatus::new("ask", "groq", "qwen/qwen3.8-27b")],
            ..Default::default()
        }),
        pianissimo: Some(PianissimoHealth { status: "ready".into(), precision: Some("fp16".into()), vocabulary: Some(12), ..Default::default() }),
        tailscale: Some(TailscaleStatus { installed: true, logged_in: true, ..Default::default() }),
        gpu: None,
        update_timer: None,
        recent_starts: Default::default(),
    }
}

/// Opens the production shell at the default window size with a status entity the test feeds.
fn open(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<StatusModel>, Entity<Shell>) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    let model = status.clone();
    let (handle, shell) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(Default::default(), size(px(720.), px(520.))))),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| Shell::new(model, window, cx)),
        )
        .expect("open test window")
    });
    (handle, status, shell)
}

fn feed(cx: &mut TestAppContext, status: &Entity<StatusModel>, overview: Overview) {
    cx.update(|cx| status.update(cx, |status, cx| status.apply(overview, cx)));
    cx.run_until_parked();
}

#[gpui_kit::test]
fn the_overview_shows_each_service_from_the_status(cx: &mut TestAppContext) {
    let (handle, status, shell) = open(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("overview-summary").label(), Some("Läser status …"));
    })
    .unwrap();

    feed(cx, &status, healthy());
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("gateway-state").label(), Some("Kör"));
        assert_eq!(window.find("pianissimo-state").label(), Some("Redo"));
        assert_eq!(window.find("tailscale-state").label(), Some("Serve saknas"));
        assert_eq!(window.find("overview-summary").label(), Some("Gateway kör · Pianissimo redo · Tailscale ok"));
        assert!(window.try_find("restart-gateway").is_some());
        assert!(window.try_find("restart-pianissimo").is_some());
    })
    .unwrap();
    cx.update(|cx| assert_eq!(shell.read(cx).page(), Page::Overview));
}

#[gpui_kit::test]
fn a_stopped_or_missing_service_reads_as_such(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    let mut overview = healthy();
    overview.transcription_unit = UnitState::Stopped;
    overview.pianissimo = None;
    overview.gateway_unit = UnitState::NotInstalled;
    overview.gateway = None;
    overview.gateway_health = None;
    feed(cx, &status, overview);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("pianissimo-state").label(), Some("Stoppad"));
        assert_eq!(window.find("gateway-state").label(), Some("Inte installerad"));
        // Nothing to restart when the service is not installed; a stopped one can be started.
        assert!(window.try_find("restart-gateway").is_none());
        assert!(window.try_find("restart-pianissimo").is_some());
    })
    .unwrap();
}

#[gpui_kit::test]
fn a_gateway_that_runs_but_does_not_answer_is_an_error(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    let mut overview = healthy();
    overview.gateway_health = Some(false);
    overview.gateway = None;
    feed(cx, &status, overview);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("gateway-state").label(), Some("Svarar inte"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn a_low_quota_is_called_out(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    let mut overview = healthy();
    overview.gateway = Some(GatewayStatus { quota: Some((190_000, 5_000, "tokens".into())), ..Default::default() });
    feed(cx, &status, overview);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("gateway-state").label(), Some("Kvoten nästan slut"));
    })
    .unwrap();
}

fn with_backup(backup: BackupStatus) -> Overview {
    let mut overview = healthy();
    overview.gateway.as_mut().unwrap().backup = Some(backup);
    overview
}

#[gpui_kit::test]
fn an_older_gateway_shows_no_backup_card(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    feed(cx, &status, healthy());
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("gateway-state").is_some());
        assert!(window.try_find("backup-state").is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn the_latest_backup_shows_when_how_many_and_where(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    feed(cx, &status, with_backup(BackupStatus { latest_at: Some(now_seconds() - 2 * 3_600), count: 3, bytes: 4_200_000 }));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("backup-state").label(), Some("Aktuell"));
        assert_eq!(window.find("backup-sparade").label(), Some("3 kopior, 4,2 MB"));
        assert_eq!(window.find("backup-plats").label(), Some("/var/lib/mio-gateway/backups/"));
        assert!(window.find("backup-note").label().is_some_and(|note| note.contains("i appen under Inställningar")));
        // "i natt", "i dag" or "i går" depending on the time zone and hour the test runs at.
        assert!(window.find("backup-senast").label().is_some_and(|when| when.starts_with("i ")));
    })
    .unwrap();
}

#[gpui_kit::test]
fn a_backup_older_than_two_days_is_a_warning(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    feed(cx, &status, with_backup(BackupStatus { latest_at: Some(now_seconds() - 3 * 86_400), count: 14, bytes: 12_345_678 }));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("backup-state").label(), Some("Äldre än två dygn"));
        assert_eq!(window.find("backup-senast").label(), Some("för 3 dagar sedan"));
        // The tooltip says why the dot is amber; the gateway itself still runs.
        assert_eq!(window.find("overview-summary").label(), Some("Gateway kör, säkerhetskopian är gammal · Pianissimo redo · Tailscale ok"));
        assert_eq!(window.find("gateway-state").label(), Some("Kör"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn no_backup_yet_says_so(cx: &mut TestAppContext) {
    let (handle, status, _) = open(cx);
    feed(cx, &status, with_backup(BackupStatus { latest_at: None, count: 0, bytes: 0 }));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("backup-state").label(), Some("Ingen än"));
        assert_eq!(window.find("backup-senast").label(), Some("Ingen säkerhetskopia än"));
        assert!(window.try_find("backup-sparade").is_none());
    })
    .unwrap();
}
