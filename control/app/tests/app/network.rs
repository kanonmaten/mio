//! Tailscale och parning against a fake helper: serve, the pairing code's lifetime and new tokens.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, Entity, TestAppContext, VisualTestContext, WindowBounds, WindowOptions, px, size};
use mio_control::model::StatusModel;
use mio_control::operation::Backend;
use mio_control::shell::{Page, Shell};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::settings::SettingsFile;
use mio_control_core::status::{Overview, TailscaleStatus};

type Calls = Arc<Mutex<Vec<Command>>>;

const PAYLOAD: &str = r#"{"mio":1,"aiURL":"https://pc.tail1234.ts.net:8443","aiToken":"abc","transcriptionURL":"https://pc.tail1234.ts.net","transcriptionToken":"def"}"#;

fn open(cx: &mut TestAppContext, tailscale: TailscaleStatus) -> (gpui_kit::AnyWindowHandle, Entity<Shell>, Calls) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let calls: Calls = Arc::default();
    let recorded = calls.clone();
    cx.update(|cx| {
        cx.set_global(Backend {
            helper: Arc::new(move |command: &Command, _: Option<&[u8]>| {
                recorded.lock().unwrap().push(command.clone());
                Ok(match command {
                    Command::PairingData => PAYLOAD.as_bytes().to_vec(),
                    _ => b"{}".to_vec(),
                })
            }),
            catalog: Arc::new(|| Err("ingen gateway i testet".into())),
            openrouter_models: Arc::new(|| Err("inte i testet".into())),
        })
    });
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    let overview = Overview { tailscale: Some(tailscale), ..Default::default() };
    cx.update(|cx| status.update(cx, |status, cx| status.apply(overview, cx)));
    let (handle, shell) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(Bounds::new(Default::default(), size(px(900.), px(1400.))))), ..Default::default() },
            cx,
            |window, cx| cx.new(|cx| Shell::new(status, window, cx)),
        )
        .expect("open test window")
    });
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(Page::Network, cx)));
    cx.run_until_parked();
    (handle, shell, calls)
}

fn logged_in(serve_443: &str) -> TailscaleStatus {
    TailscaleStatus {
        installed: true,
        logged_in: true,
        host: Some("pc.tail1234.ts.net".into()),
        serve_443: Some(serve_443.into()),
        serve_8443: Some("http://127.0.0.1:8787".into()),
        ..Default::default()
    }
}

fn step(cx: &mut TestAppContext, handle: gpui_kit::AnyWindowHandle, act: impl FnOnce(&mut gpui_kit::Window, &mut gpui_kit::App)) {
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        act(window, cx);
    })
    .unwrap();
    cx.run_until_parked();
}

#[gpui_kit::test]
fn the_pairing_code_hides_after_a_minute(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx, logged_in("http://127.0.0.1:8765"));
    step(cx, handle, |window, cx| {
        assert!(window.try_find("setup-serve").is_none(), "serve is already right");
        window.click("show-pairing", cx);
    });
    step(cx, handle, |window, _| assert_eq!(window.find("pairing-code").label(), Some("Parningskod, döljs om 60 s")));
    assert_eq!(*calls.lock().unwrap(), [Command::PairingData]);
    cx.executor().advance_clock(Duration::from_secs(59));
    step(cx, handle, |window, _| assert_eq!(window.find("pairing-code").label(), Some("Parningskod, döljs om 1 s")));
    cx.executor().advance_clock(Duration::from_secs(1));
    step(cx, handle, |window, _| assert!(window.try_find("pairing-code").is_none()));
}

#[gpui_kit::test]
fn the_pairing_code_hides_when_the_window_loses_focus(cx: &mut TestAppContext) {
    let (handle, _, _) = open(cx, logged_in("http://127.0.0.1:8765"));
    step(cx, handle, |window, _| window.activate_window());
    step(cx, handle, |window, cx| {
        assert!(window.is_window_active());
        window.click("show-pairing", cx);
    });
    step(cx, handle, |window, _| assert!(window.try_find("pairing-code").is_some()));
    VisualTestContext::from_window(handle, cx).deactivate_window();
    step(cx, handle, |window, _| assert!(window.try_find("pairing-code").is_none()));
}

#[gpui_kit::test]
fn wrong_serve_offers_the_fix_and_a_new_token_restarts_the_service(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx, logged_in("http://127.0.0.1:3000"));
    step(cx, handle, |window, cx| window.click("setup-serve", cx));
    assert_eq!(*calls.lock().unwrap(), [Command::SetupServe]);
    calls.lock().unwrap().clear();
    step(cx, handle, |window, cx| window.click("rotate-gateway", cx));
    assert!(calls.lock().unwrap().is_empty(), "the first click only asks");
    step(cx, handle, |window, cx| window.click("confirm-rotate-button", cx));
    assert_eq!(*calls.lock().unwrap(), [Command::RotateToken(SettingsFile::Gateway), Command::Unit(UnitAction::Restart, Unit::Gateway)]);
    step(cx, handle, |window, _| assert!(window.try_find("confirm-rotate").is_none()));
}
