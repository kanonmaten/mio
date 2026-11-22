//! Uppdateringar against a fake probe and terminal: the rows, "Uppdatera allt" and the dirty-repo stop.

use std::sync::{Arc, Mutex};

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::model::StatusModel;
use mio_control::shell::{Page, Shell};
use mio_control::updates::UpdateBackend;
use mio_control_core::updates::{Part, PartState, RepoState, UpdateState};

fn state(dirty: bool) -> UpdateState {
    UpdateState {
        repo: Ok(RepoState { head: "0".repeat(40), behind: 3, dirty, fetch_failed: false }),
        parts: vec![(Part::Gateway, PartState::Behind), (Part::Pianissimo, PartState::UpToDate), (Part::Panel, PartState::UpToDate)],
        system: Ok(4),
    }
}

fn open(cx: &mut TestAppContext, dirty: bool) -> (gpui_kit::AnyWindowHandle, Arc<Mutex<Vec<String>>>) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let scripts: Arc<Mutex<Vec<String>>> = Arc::default();
    let opened = scripts.clone();
    cx.update(|cx| {
        cx.set_global(UpdateBackend {
            probe: Arc::new(move || state(dirty)),
            open_terminal: Arc::new(move |script| {
                opened.lock().unwrap().push(script);
                Ok(())
            }),
            autostart: Arc::new(|| true),
        })
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
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(Page::Updates, cx)));
    cx.run_until_parked();
    (handle, scripts)
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
fn update_all_runs_only_what_is_behind_in_one_ghostty(cx: &mut TestAppContext) {
    let (handle, scripts) = open(cx, false);
    step(cx, handle, |window, cx| {
        assert!(window.try_find("updates-blocked").is_none());
        window.click("update-all", cx);
    });
    let scripts = scripts.lock().unwrap();
    assert_eq!(scripts.len(), 1);
    let script = &scripts[0];
    for expected in ["git pull --ff-only", "./server/install.sh", "/opt/mio-transcription/update-model.sh", "sudo pacman -Syu"] {
        assert!(script.contains(expected), "{expected} missing");
    }
    assert!(!script.contains("./transcription-server/install.sh") && !script.contains("./control/install.sh"));
}

#[gpui_kit::test]
fn local_changes_stop_the_pull_but_not_system_packages(cx: &mut TestAppContext) {
    let (handle, scripts) = open(cx, true);
    step(cx, handle, |window, cx| {
        assert!(window.try_find("updates-blocked").is_some());
        window.click("update-all", cx);
        window.click("update-gateway", cx);
    });
    assert!(scripts.lock().unwrap().is_empty(), "nothing that pulls may run");
    step(cx, handle, |window, cx| window.click("update-system", cx));
    assert_eq!(scripts.lock().unwrap().len(), 1);
    assert!(scripts.lock().unwrap()[0].contains("sudo pacman -Syu"));
}
