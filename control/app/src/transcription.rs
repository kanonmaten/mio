//! Transkription: Pianissimo's precision, preprocessing, speaker labels, word-list strength,
//! the model version with "Uppdatera nu", the nightly update and the pinned speaker model.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::radio::RadioGroup;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::slider::{Slider, SliderEvent, SliderState, SliderValue};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, Sizable as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::ai_settings::GatewayFile;
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::settings::SettingsFile;
use mio_control_core::transcription_settings::TranscriptionForm;
use serde_json::Value;

use crate::model::StatusModel;
use crate::operation;
use crate::parts::{page_header, render_changes, section};

struct Editor {
    file: GatewayFile,
    form: TranscriptionForm,
    boost: Entity<SliderState>,
    pinned_speaker_model: Option<String>,
    _subscriptions: Vec<Subscription>,
}

enum Stage {
    Closed,
    Loading,
    Editing(Box<Editor>),
    Failed(SharedString),
}

pub struct TranscriptionPage {
    status: Entity<StatusModel>,
    stage: Stage,
    /// The command running now (save, model update, timer), so its button shows progress.
    busy: Option<&'static str>,
    _observe: Subscription,
}

impl TranscriptionPage {
    pub fn new(status: Entity<StatusModel>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        Self { status, stage: Stage::Closed, busy: None, _observe: observe }
    }

    pub fn open_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.stage = Stage::Loading;
        cx.notify();
        let task = operation::run(Command::ReadSettings(SettingsFile::Transcription), None, cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.stage = match result {
                    Err(error) => Stage::Failed(error.to_string().into()),
                    Ok(bytes) => match serde_json::from_slice::<Value>(&bytes).ok().and_then(|json| GatewayFile::parse(&json)) {
                        None => Stage::Failed("Pianissimo är inte installerat. Kör transcription-server/install.sh först.".into()),
                        Some(file) => Stage::Editing(Box::new(Self::build_editor(file, window, cx))),
                    },
                };
                cx.notify();
            });
        })
        .detach();
    }

    fn build_editor(file: GatewayFile, window: &mut Window, cx: &mut Context<Self>) -> Editor {
        let form = TranscriptionForm::from_file(&file);
        let boost = cx.new(|_| SliderState::new().min(0.0).max(2.0).step(0.1).default_value(form.boost as f32));
        let subscription = cx.subscribe_in(&boost, window, |this, _, event: &SliderEvent, _, cx| {
            let (SliderEvent::Change(SliderValue::Single(value)) | SliderEvent::Release(SliderValue::Single(value))) = event else { return };
            if let Stage::Editing(editor) = &mut this.stage {
                editor.form.boost = (f64::from(*value) * 10.0).round() / 10.0;
                cx.notify();
            }
        });
        let pinned_speaker_model = file.values.get("MIO_DIARIZATION_REVISION").filter(|value| !value.is_empty()).cloned();
        Editor { file, form, boost, pinned_speaker_model, _subscriptions: vec![subscription] }
    }

    fn edit(&mut self, cx: &mut Context<Self>, change: impl FnOnce(&mut TranscriptionForm)) {
        if let Stage::Editing(editor) = &mut self.stage {
            change(&mut editor.form);
            cx.notify();
        }
    }

    /// Runs one helper command with progress on its button and a notification when done.
    fn run(&mut self, id: &'static str, (command, stdin): (Command, Option<Vec<u8>>), done: &'static str, then_restart: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy.is_some() {
            return;
        }
        self.busy = Some(id);
        cx.notify();
        let first = operation::run(command, stdin, cx);
        let status = self.status.clone();
        cx.spawn_in(window, async move |this, cx| {
            let mut result = first.await;
            if result.is_ok() && then_restart {
                let restart = this.update(cx, |_, cx| operation::run(Command::Unit(UnitAction::Restart, Unit::Transcription), None, cx));
                if let Ok(restart) = restart {
                    result = restart.await;
                }
            }
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = None;
                window.push_notification(match result {
                    Ok(_) => Notification::success(done),
                    Err(error) => Notification::error(error.to_string()),
                }, cx);
                status.update(cx, |status, cx| status.request_refresh(cx));
                if then_restart {
                    this.open_editor(window, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Stage::Editing(editor) = &self.stage else { return };
        let changes = editor.form.changes(&editor.file);
        if changes.is_empty() || !editor.form.problems().is_empty() {
            return;
        }
        let request = TranscriptionForm::request(&changes).to_string().into_bytes();
        self.run("save-transcription", (Command::WriteSettings(SettingsFile::Transcription), Some(request)),
            "Sparat. Pianissimo startas om och laddar modellen igen (cirka en minut).", true, window, cx);
    }

    fn render_current(&self, cx: &Context<Self>) -> impl IntoElement {
        let overview = self.status.read(cx).overview();
        let rows: Vec<(&str, String)> = match &overview.pianissimo {
            None => vec![("Läge", overview.transcription_unit.label().to_owned())],
            Some(health) => vec![
                ("Läge", if health.is_ready() { "Redo".to_owned() } else { "Laddar".to_owned() }),
                ("Modellversion", health.revision.clone().unwrap_or_default().chars().take(12).collect()),
                ("Precision", health.precision.clone().unwrap_or_default().to_uppercase()),
                ("Talarmärkning", health.speaker_labels.clone().unwrap_or_default()),
                ("Egna ord", health.vocabulary.map_or(String::new(), |words| words.to_string())),
            ],
        };
        v_flex().gap_1().text_sm().children(rows.into_iter().map(|(label, value)| {
            h_flex().gap_3().justify_between().child(div().text_color(cx.theme().muted_foreground).child(label)).child(value)
        }))
    }

    fn render_editor(&self, editor: &Editor, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let form = &editor.form;
        let changes = form.changes(&editor.file);
        let problems = form.problems();
        let timer_on = self.status.read(cx).overview().update_timer.as_ref().is_some_and(|timer| timer.enabled);
        let muted = |text: &str| div().text_xs().text_color(theme.muted_foreground).child(text.to_owned());
        v_flex()
            .gap_3()
            .child(section("Precision"))
            .child(
                RadioGroup::new("precision")
                    .children(["FP16 (standard, snabbare)", "FP32"])
                    .selected_index(Some(if form.precision == "fp32" { 1 } else { 0 }))
                    .on_change(cx.listener(|this, index: &usize, _, cx| {
                        this.edit(cx, |form| form.precision = if *index == 1 { "fp32" } else { "fp16" }.to_owned())
                    })),
            )
            .child(muted("FP16 är NeMos blandade precision; mät gärna ordfelen med scripts/measure_wer.py --precision fp32 fp16 (se transcription-server/README.md#fp16)."))
            .child(section("Ljud och talare"))
            .child(Switch::new("preprocess").label("Förbehandling (högpass och nivåutjämning)").checked(form.preprocess)
                .on_change(cx.listener(|this, on: &bool, _, cx| this.edit(cx, |form| form.preprocess = *on))))
            .child(Switch::new("speaker-labels").label("Talarmärkning").checked(form.speaker_labels)
                .on_change(cx.listener(|this, on: &bool, _, cx| this.edit(cx, |form| form.speaker_labels = *on))))
            .child(section("Ordlistans styrka"))
            .child(h_flex().gap_3().child(div().flex_1().child(Slider::new(&editor.boost).accessibility_label("Ordlistans styrka")))
                .child(div().id("boost-value").test_support().aria_label(format!("{:.1}", form.boost)).w_10().child(format!("{:.1}", form.boost))))
            .when(form.boost_is_high(), |list| {
                list.child(h_flex().gap_2().text_sm().child(Icon::new(IconName::TriangleAlert).text_color(theme.warning))
                    .child("Över 1,0 kan listade ord skrivas fast de inte sades."))
            })
            .child(muted("0 stänger av egna ord. 1,0 är standard."))
            .child(section("Modellen"))
            .child(h_flex().gap_2()
                .child(Button::new("update-model").label("Uppdatera nu").icon(IconName::RefreshCw).loading(self.busy == Some("update-model"))
                    .disabled(self.busy.is_some())
                    .on_click(cx.listener(|this, _, window, cx| this.run("update-model", (Command::UpdateModel, None),
                        "Pianissimo är uppdaterad (eller redan senaste versionen).", false, window, cx))))
                .child(Switch::new("nightly").label("Uppdatera varje natt").checked(timer_on).disabled(self.busy.is_some())
                    .on_change(cx.listener(|this, on: &bool, window, cx| {
                        let done = if *on { "Nattuppdateringen är på." } else { "Nattuppdateringen är av." };
                        this.run("nightly", (Command::UpdateTimer(*on), None), done, false, window, cx)
                    }))))
            .child(muted("En ny version som inte blir redo inom fem minuter rullas tillbaka automatiskt."))
            .child(section("Talarmodellen"))
            .child(match &editor.pinned_speaker_model {
                Some(revision) => h_flex().gap_3().justify_between().text_sm()
                    .child(format!("Låst till {}", revision.chars().take(12).collect::<String>()))
                    .child(Button::new("unpin-speakers").small().label(if form.unpin_diarization { "Ångra" } else { "Byt till senaste" })
                        .on_click(cx.listener(|this, _, _, cx| this.edit(cx, |form| form.unpin_diarization = !form.unpin_diarization))))
                    .into_any_element(),
                None => muted("Ingen låst version; transcription-server/install.sh väljer senaste.").into_any_element(),
            })
            .when(form.unpin_diarization, |list| list.child(muted("Efter sparandet: kör transcription-server/install.sh så hämtas och låses den senaste talarmodellen. Tills dess körs Pianissimo utan talarmärkning.")))
            .child(section("Ändringar"))
            .child(render_changes(&changes, &theme))
            .children(problems.into_iter().map(|problem| h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(theme.danger)).child(problem)))
            .child(h_flex().justify_end().child(
                Button::new("save-transcription").primary().label("Spara och starta om")
                    .loading(self.busy == Some("save-transcription"))
                    .disabled(changes.is_empty() || self.busy.is_some())
                    .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
            ))
    }
}

impl Render for TranscriptionPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body = match &self.stage {
            Stage::Closed => v_flex().gap_3().child(self.render_current(cx))
                .child(h_flex().child(Button::new("edit-transcription").label("Ändra…").icon(IconName::Settings)
                    .on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Loading => crate::parts::loading_line("Läser inställningarna …", cx).into_any_element(),
            Stage::Failed(message) => v_flex().gap_3()
                .child(h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(cx.theme().danger)).child(message.clone()))
                .child(h_flex().child(Button::new("retry-transcription").label("Försök igen").on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Editing(editor) => self.render_editor(editor, cx).into_any_element(),
        };
        v_flex().id("transcription").size_full().overflow_y_scrollbar()
            .child(v_flex().p_4().gap_4()
                .child(page_header("Transkription", "Hur Pianissimo gör om ljud till text på grafikkortet.", cx))
                .child(body))
    }
}
