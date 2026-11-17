//! Kom igång and Datorn against fakes: the guide's first open step, its Konsole install and the
//! pairing hand-off; keeping awake, the login entry and the saved preferences.

use std::any::Any;
use std::sync::{Arc, Mutex};

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::computer::ComputerBackend;
use mio_control::model::StatusModel;
use mio_control::operation::Backend;
use mio_control::shell::{Page, Shell};
use mio_control::updates::UpdateBackend;
use mio_control_core::command::Command;
use mio_control_core::computer::Preferences;
use mio_control_core::status::{GpuStatus, Overview, TailscaleStatus};

const PAYLOAD: &str = r#"{"mio":1,"aiURL":"https://pc.tail1234.ts.net:8443","aiToken":"abc"}"#;

struct Fakes {
    scripts: Arc<Mutex<Vec<String>>>,
    inhibitions: Arc<Mutex<u32>>,
    folder: tempfile::TempDir,
}

fn open(cx: &mut TestAppContext, page: Page) -> (gpui_kit::AnyWindowHandle, Entity<Shell>, Fakes) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let fakes = Fakes { scripts: Arc::default(), inhibitions: Arc::default(), folder: tempfile::tempdir().unwrap() };
    let (scripts, inhibitions) = (fakes.scripts.clone(), fakes.inhibitions.clone());
    let folder = fakes.folder.path().to_path_buf();
    cx.update(|cx| {
        cx.set_global(Backend {
            helper: Arc::new(|command: &Command, _: Option<&[u8]>| {
                Ok(if *command == Command::PairingData { PAYLOAD.as_bytes().to_vec() } else { b"{}".to_vec() })
            }),
            catalog: Arc::new(|| Err("ingen gateway i testet".into())),
        });
        cx.set_global(UpdateBackend {
            probe: Arc::new(|| unreachable!("the guide never probes")),
            open_terminal: Arc::new(move |script| {
                scripts.lock().unwrap().push(script);
                Ok(())
            }),
            autostart: Arc::new(|| true),
        });
        cx.set_global(ComputerBackend {
            inhibit: Arc::new(move || {
                *inhibitions.lock().unwrap() += 1;
                Ok(Box::new(()) as Box<dyn Any>)
            }),
            preferences: Some(folder.join("mio-control/installningar")),
            autostart: Some(folder.join("autostart/app.mio.control.desktop")),
        });
    });
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    // Driver and Tailscale are there; nothing is installed yet.
    let overview = Overview {
        gpu: Some(GpuStatus { name: "NVIDIA GeForce RTX 4070".into(), ..Default::default() }),
        tailscale: Some(TailscaleStatus { installed: true, logged_in: true, ..Default::default() }),
        ..Default::default()
    };
    cx.update(|cx| status.update(cx, |status, cx| status.apply(overview, cx)));
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
    (handle, shell, fakes)
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
fn the_guide_starts_at_the_gateway_and_installs_it_in_konsole(cx: &mut TestAppContext) {
    let (handle, shell, fakes) = open(cx, Page::Setup);
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("setup-step").label(), Some("AI-gatewayen: inte klart"));
        window.click("run-1", cx);
    });
    let scripts = fakes.scripts.lock().unwrap().clone();
    assert_eq!(scripts.len(), 1);
    assert!(scripts[0].contains("./server/install.sh") && !scripts[0].contains("git pull"), "installs without pulling");

    // The last step hands over to Tailscale och parning with the code showing.
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(Page::Setup, cx)));
    step(cx, handle, |window, cx| window.click(gpui_kit::ElementId::NamedInteger("trigger".into(), 4), cx));
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("setup-step").label(), Some("Para telefonen: inte klart"));
        window.click("run-4", cx);
    });
    assert_eq!(cx.update(|cx| shell.read(cx).page()), Page::Network);
    step(cx, handle, |window, _| assert!(window.try_find("pairing-code").is_some()));
}

#[gpui_kit::test]
fn datorn_keeps_awake_and_saves_its_choices(cx: &mut TestAppContext) {
    let (handle, _, fakes) = open(cx, Page::Computer);
    let folder = fakes.folder.path();
    step(cx, handle, |window, cx| {
        window.click("keep-awake", cx);
        window.click("autostart", cx);
        window.click("tray", cx);
    });
    assert_eq!(*fakes.inhibitions.lock().unwrap(), 1);
    assert!(folder.join("autostart/app.mio.control.desktop").exists());
    assert_eq!(Preferences::load(&folder.join("mio-control/installningar")), Preferences { keep_awake: true, tray: false });
    step(cx, handle, |window, cx| {
        window.click("keep-awake", cx);
        window.click("autostart", cx);
    });
    assert!(!cx.update(|cx| mio_control::computer::is_awake(cx)));
    assert!(!folder.join("autostart/app.mio.control.desktop").exists());
}
