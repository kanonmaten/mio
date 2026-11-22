//! Egna ord: the vocabulary Pianissimo boosts. The words stay on this computer: the helper reads
//! and writes the file, the panel shows them, and nothing else sees them.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::settings::{VOCABULARY_MAX_BYTES, VOCABULARY_MAX_PHRASES, check_vocabulary, vocabulary_is_writable};
use mio_control_core::transcription_settings::sort_vocabulary;

use crate::model::StatusModel;
use crate::operation;
use crate::parts::page_header;

enum Stage {
    Closed,
    Loading,
    Editing { saved: String, editor: Entity<TextareaState>, _subscription: Subscription },
    Failed(SharedString),
}

pub struct WordsPage {
    status: Entity<StatusModel>,
    stage: Stage,
    saving: bool,
    _observe: Subscription,
}

impl WordsPage {
    pub fn new(status: Entity<StatusModel>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        Self { status, stage: Stage::Closed, saving: false, _observe: observe }
    }

    pub fn open_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.stage = Stage::Loading;
        cx.notify();
        let task = operation::run(Command::ReadVocabulary, None, cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.stage = match result {
                    Err(error) => Stage::Failed(error.to_string().into()),
                    Ok(bytes) => {
                        let saved = String::from_utf8_lossy(&bytes).into_owned();
                        let text = saved.clone();
                        let editor = cx.new(|cx| TextareaState::new(window, cx).default_value(text));
                        let subscription = cx.subscribe_in(&editor, window, |_, _, event: &InputEvent, _, cx| {
                            if matches!(event, InputEvent::Change) {
                                cx.notify();
                            }
                        });
                        Stage::Editing { saved, editor, _subscription: subscription }
                    }
                };
                cx.notify();
            });
        })
        .detach();
    }

    fn sort(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Stage::Editing { editor, .. } = &self.stage {
            let sorted = sort_vocabulary(&editor.read(cx).value());
            editor.update(cx, |editor, cx| editor.set_value(sorted, window, cx));
            cx.notify();
        }
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Stage::Editing { editor, .. } = &self.stage else { return };
        let text = editor.read(cx).value().to_string();
        if self.saving || vocabulary_is_writable(text.as_bytes()).is_err() {
            return;
        }
        self.saving = true;
        cx.notify();
        let write = operation::run(Command::WriteVocabulary, Some(text.into_bytes()), cx);
        let status = self.status.clone();
        cx.spawn_in(window, async move |this, cx| {
            let mut result = write.await;
            if result.is_ok() {
                // Pianissimo reads the list when it loads the model.
                if let Ok(restart) = this.update(cx, |_, cx| operation::run(Command::Unit(UnitAction::Restart, Unit::Transcription), None, cx)) {
                    result = restart.await;
                }
            }
            let _ = this.update_in(cx, |this, window, cx| {
                this.saving = false;
                window.push_notification(match result {
                    Ok(_) => Notification::success("Ordlistan sparades. Pianissimo startas om och läser in den."),
                    Err(error) => Notification::error(error.to_string()),
                }, cx);
                status.update(cx, |status, cx| status.request_refresh(cx));
                this.open_editor(window, cx);
            });
        })
        .detach();
    }
}

impl Render for WordsPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let active = self.status.read(cx).overview().pianissimo.as_ref().and_then(|health| health.vocabulary);
        let body = match &self.stage {
            Stage::Closed => v_flex()
                .gap_3()
                .child(div().text_sm().child(match active {
                    Some(words) => format!("{words} egna ord är aktiva i Pianissimo."),
                    None => "Pianissimo svarar inte just nu, så antalet aktiva ord syns inte.".to_owned(),
                }))
                .child(h_flex().child(Button::new("edit-words").label("Öppna ordlistan…").icon(IconName::FileText)
                    .on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Loading => crate::parts::loading_line("Läser ordlistan …", cx).into_any_element(),
            Stage::Failed(message) => v_flex().gap_3()
                .child(h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(theme.danger)).child(message.clone()))
                .child(h_flex().child(Button::new("retry-words").label("Försök igen").on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Editing { saved, editor, .. } => {
                let text = editor.read(cx).value().to_string();
                let report = check_vocabulary(&text);
                let writable = vocabulary_is_writable(text.as_bytes());
                let changed = text != *saved;
                let count: SharedString = format!("{} av högst {VOCABULARY_MAX_PHRASES} ord används", report.phrases).into();
                let warning = |text: String| h_flex().gap_2().text_sm().child(Icon::new(IconName::TriangleAlert).text_color(theme.warning)).child(text);
                v_flex()
                    .gap_3()
                    .child(div().id("words-count").test_support().aria_label(count.clone()).text_sm().child(count))
                    .child(div().id("words-editor").test_support().h_80().child(Textarea::new(editor).h_full()))
                    .when(!report.too_long.is_empty(), |list| list.child(warning(format!(
                        "Rad {} är längre än {VOCABULARY_MAX_BYTES} byte och hoppas över.", join(&report.too_long)))))
                    .when(!report.duplicates.is_empty(), |list| list.child(warning(format!("Rad {} upprepar ett ord.", join(&report.duplicates)))))
                    .when(report.ignored_over_limit > 0, |list| list.child(warning(format!(
                        "{} ord efter de första {VOCABULARY_MAX_PHRASES} används inte.", report.ignored_over_limit))))
                    .when_some(writable.err(), |list, message| list.child(h_flex().gap_2().text_sm()
                        .child(Icon::new(IconName::CircleX).text_color(theme.danger)).child(message)))
                    .child(h_flex().gap_2().justify_end()
                        .child(Button::new("sort-words").label("Sortera").on_click(cx.listener(|this, _, window, cx| this.sort(window, cx))))
                        .child(Button::new("save-words").primary().label("Spara och starta om").loading(self.saving)
                            .disabled(!changed || self.saving || vocabulary_is_writable(text.as_bytes()).is_err())
                            .on_click(cx.listener(|this, _, window, cx| this.save(window, cx)))))
                    .into_any_element()
            }
        };
        v_flex().id("words").size_full().p_4().gap_4()
            .child(page_header("Egna ord", "Namn och facktermer som Pianissimo ska stava rätt. Ett ord eller en fras per rad; # är kommentar. Orden lämnar aldrig datorn.", cx))
            .child(body)
    }
}

fn join(lines: &[usize]) -> String {
    let shown: Vec<String> = lines.iter().take(5).map(usize::to_string).collect();
    let more = if lines.len() > 5 { format!(" och {} till", lines.len() - 5) } else { String::new() };
    format!("{}{more}", shown.join(", "))
}
