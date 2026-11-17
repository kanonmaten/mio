//! Transkription and Egna ord against a fake helper.

use std::sync::{Arc, Mutex};

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::model::StatusModel;
use mio_control::operation::Backend;
use mio_control::shell::{Page, Shell};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::settings::SettingsFile;
use serde_json::{Value, json};

type Calls = Arc<Mutex<Vec<(Command, Option<Vec<u8>>)>>>;

fn open(cx: &mut TestAppContext, page: Page) -> (gpui_kit::AnyWindowHandle, Entity<Shell>, Calls) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let calls: Calls = Arc::default();
    let recorded = calls.clone();
    cx.update(|cx| {
        cx.set_global(Backend {
            helper: Arc::new(move |command: &Command, stdin: Option<&[u8]>| {
                recorded.lock().unwrap().push((command.clone(), stdin.map(<[u8]>::to_vec)));
                Ok(match command {
                    Command::ReadSettings(SettingsFile::Transcription) => json!({ "exists": true,
                        "values": { "MIO_MODEL_ID": "KlangAI/pianissimo-sv", "MIO_MODEL_REVISION": "0123456789abcdef0123456789abcdef01234567" },
                        "secrets": { "MIO_TRANSCRIPTION_TOKEN": true } }).to_string().into_bytes(),
                    Command::ReadVocabulary => "# Egna ord\nÅsa Lindqvist\n".as_bytes().to_vec(),
                    _ => b"{}".to_vec(),
                })
            }),
            catalog: Arc::new(|| Err("ingen gateway i testet".into())),
        })
    });
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    let (handle, shell) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(Bounds::new(Default::default(), size(px(900.), px(1400.))))), ..Default::default() },
            cx,
            |window, cx| cx.new(|cx| Shell::new(status, window, cx)),
        )
        .expect("open test window")
    });
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(page, cx)));
    (handle, shell, calls)
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
fn a_new_word_is_counted_and_saved_then_pianissimo_restarts(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx, Page::Words);
    step(cx, handle, |window, cx| window.click("edit-words", cx));
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("words-count").label(), Some("1 av högst 500 ord används"));
        window.click("words-editor", cx);
        window.press("ctrl-end", cx);
        window.input("Installationsteknik\n", cx);
    });
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("words-count").label(), Some("2 av högst 500 ord används"));
        window.click("save-words", cx);
    });
    let calls = calls.lock().unwrap();
    let (_, written) = calls.iter().find(|(command, _)| *command == Command::WriteVocabulary).expect("the list was written");
    assert_eq!(String::from_utf8(written.clone().unwrap()).unwrap(), "# Egna ord\nÅsa Lindqvist\nInstallationsteknik\n");
    assert!(calls.iter().any(|(command, _)| *command == Command::Unit(UnitAction::Restart, Unit::Transcription)));
}

#[gpui_kit::test]
fn turning_off_speaker_labels_is_shown_and_saved(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx, Page::Transcription);
    step(cx, handle, |window, cx| window.click("edit-transcription", cx));
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("changes").label(), Some("Inga ändringar."));
        window.click("speaker-labels", cx);
    });
    step(cx, handle, |window, cx| {
        assert_eq!(window.find("changes").label(), Some("1 ändringar"));
        window.click("save-transcription", cx);
    });
    let calls = calls.lock().unwrap();
    let (_, stdin) = calls.iter().find(|(command, _)| *command == Command::WriteSettings(SettingsFile::Transcription)).expect("settings were written");
    let request: Value = serde_json::from_slice(stdin.as_ref().unwrap()).unwrap();
    assert_eq!(request, json!({ "set": { "MIO_SPEAKER_LABELS": "0" }, "remove": [] }));
    assert!(calls.iter().any(|(command, _)| *command == Command::Unit(UnitAction::Restart, Unit::Transcription)));
}
