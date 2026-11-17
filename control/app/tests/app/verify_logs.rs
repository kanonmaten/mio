//! Verifiering and Loggar against fakes: streamed output and the receipt, the level filter and
//! follow mode.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::logs::LogBackend;
use mio_control::model::StatusModel;
use mio_control::shell::{Page, Shell};
use mio_control::verify::VerifyBackend;
use mio_control_core::journal::{Entry, Read};
use mio_control_core::verification::{GateResult, Receipt};

fn entry(cursor: &str, priority: u8) -> Entry {
    Entry { cursor: cursor.into(), time: 1_763_370_000, priority, message: format!("rad {cursor}") }
}

fn open(cx: &mut TestAppContext, page: Page) -> (gpui_kit::AnyWindowHandle, Arc<Mutex<Vec<Option<String>>>>) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let reads: Arc<Mutex<Vec<Option<String>>>> = Arc::default();
    let seen = reads.clone();
    let ran = Arc::new(Mutex::new(false));
    let finished = ran.clone();
    cx.update(|cx| {
        cx.set_global(VerifyBackend {
            run: Arc::new(move |line| {
                line("RUN structure".into());
                line("PASS structure".into());
                *finished.lock().unwrap() = true;
                Ok(true)
            }),
            receipt: Arc::new(move || {
                ran.lock().unwrap().then(|| Receipt {
                    result: "PASS (Linux synthetic gates)".into(),
                    finished_at: None,
                    commit: Some("1b924cf".into()),
                    dirty: false,
                    gates: vec![GateResult { gate: "structure".into(), result: "PASS".into(), seconds: Some("1 s".into()) }],
                })
            }),
        });
        cx.set_global(LogBackend {
            read: Arc::new(move |_, after| {
                seen.lock().unwrap().push(after.clone());
                Ok(Read {
                    entries: match after.as_deref() {
                        None => vec![entry("1", 3), entry("2", 6), entry("3", 7)],
                        Some("3") => vec![entry("4", 4)],
                        Some(_) => vec![],
                    },
                    hint: None,
                })
            }),
        });
    });
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    let (handle, shell) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(Bounds::new(Default::default(), size(px(900.), px(1000.))))), ..Default::default() },
            cx,
            |window, cx| cx.new(|cx| Shell::new(status, window, cx)),
        )
        .expect("open test window")
    });
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(page, cx)));
    cx.run_until_parked();
    (handle, reads)
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
fn verification_streams_its_output_then_shows_the_receipt(cx: &mut TestAppContext) {
    let (handle, _) = open(cx, Page::Verify);
    step(cx, handle, |window, cx| {
        assert!(window.try_find("receipt").is_none());
        window.click("run-verify", cx);
    });
    step(cx, handle, |window, _| {
        assert_eq!(window.find("verify-output").label(), Some("2 rader"));
        assert_eq!(window.find("verify-result").label(), Some("Alla grindar som går att köra här gick igenom."));
        assert_eq!(window.find("receipt").label(), Some("PASS (Linux synthetic gates)"));
    });
}

#[gpui_kit::test]
fn logs_filter_by_level_and_follow_new_lines(cx: &mut TestAppContext) {
    let (handle, reads) = open(cx, Page::Logs);
    // Info hides priority 7 (debug).
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("log-count").label(), Some("2 rader"));
        window.click("follow", cx);
    });
    cx.executor().advance_clock(Duration::from_secs(2));
    step(cx, handle, |window, _| assert_eq!(window.find("log-count").label(), Some("3 rader")));
    assert_eq!(*reads.lock().unwrap(), [None, Some("3".to_owned())]);
}
