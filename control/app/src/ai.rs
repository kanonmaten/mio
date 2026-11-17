//! AI: which reviewed model each task uses, the gateway's limits, provider keys, and a test call
//! the user starts. Nothing is written before the "före → efter" list has been shown, and the
//! gateway checks the file again before the helper writes it.


use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::select::{Select, SelectEvent, SelectState};
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, IndexPath, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::ai_settings::{AiForm, Catalog, Change, GatewayFile, LIMITS, Pair, TASKS, provider_name};
use mio_control_core::command::{Command, PROVIDER_IDS, Unit, UnitAction};
use mio_control_core::settings::{PROVIDER_SECRET_KEYS, SettingsFile};
use serde_json::Value;

use crate::model::StatusModel;
use crate::operation;

type Choice = SelectState<Vec<SharedString>>;

/// The editor once settings and model list are read.
struct Editor {
    file: GatewayFile,
    catalog: Catalog,
    form: AiForm,
    default_select: Entity<Choice>,
    task_selects: Vec<(&'static str, Entity<Choice>)>,
    limit_inputs: Vec<(&'static str, Entity<InputState>)>,
    key_provider: Entity<Choice>,
    key_input: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

enum Stage {
    /// Only the passwordless status is shown.
    Closed,
    Loading,
    Editing(Box<Editor>),
    Failed(SharedString),
}

/// One finished "Prova" run, shown under the model list.
struct TrialReport {
    label: String,
    passed: bool,
    lines: Vec<String>,
}

pub struct AiPage {
    status: Entity<StatusModel>,
    stage: Stage,
    saving: bool,
    trying: Option<String>,
    trial: Option<TrialReport>,
    _observe: Subscription,
}

const SAME: &str = "Samma som standard";

impl AiPage {
    pub fn new(status: Entity<StatusModel>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        Self { status, stage: Stage::Closed, saving: false, trying: None, trial: None, _observe: observe }
    }

    /// Reads `gateway.env` through the helper (KDE asks for the password once) and the model list.
    pub fn open_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.stage = Stage::Loading;
        cx.notify();
        let settings = operation::run(Command::ReadSettings(SettingsFile::Gateway), None, cx);
        let catalog = operation::catalog(cx);
        cx.spawn_in(window, async move |this, cx| {
            let (settings, catalog) = (settings.await, catalog.await);
            let _ = this.update_in(cx, |this, window, cx| {
                this.stage = match (settings, catalog) {
                    (Err(error), _) => Stage::Failed(error.to_string().into()),
                    (_, Err(message)) => Stage::Failed(message.into()),
                    (Ok(settings), Ok(catalog)) => {
                        let file = serde_json::from_slice::<Value>(&settings).ok().and_then(|json| GatewayFile::parse(&json));
                        let catalog = serde_json::from_slice::<Value>(&catalog).ok().and_then(|json| Catalog::parse(&json));
                        match (file, catalog) {
                            (Some(file), Some(catalog)) => Stage::Editing(Box::new(this.build_editor(file, catalog, window, cx))),
                            (None, _) => Stage::Failed("AI-gatewayen är inte installerad. Kör server/install.sh först.".into()),
                            (_, None) => Stage::Failed("Gatewayens modellista gick inte att läsa.".into()),
                        }
                    }
                };
                cx.notify();
            });
        })
        .detach();
    }

    fn build_editor(&mut self, file: GatewayFile, catalog: Catalog, window: &mut Window, cx: &mut Context<Self>) -> Editor {
        let form = AiForm::from_file(&file);
        let labels: Vec<SharedString> = catalog.reviewed.iter().map(|pair| pair.label().into()).collect();
        let index_of = |pair: &(String, String)| catalog.reviewed.iter().position(|known| known.is(&pair.0, &pair.1));
        let mut subscriptions = Vec::new();

        let default_index = index_of(&form.default_pair).map(|row| IndexPath::default().row(row));
        let default_select = cx.new(|cx| SelectState::new(labels.clone(), default_index, window, cx));
        subscriptions.push(cx.subscribe_in(&default_select, window, |this, _, event: &SelectEvent<Vec<SharedString>>, _, cx| {
            let SelectEvent::Confirm(Some(label)) = event else { return };
            if let Stage::Editing(editor) = &mut this.stage
                && let Some(pair) = editor.catalog.reviewed.iter().find(|pair| pair.label() == label.as_ref())
            {
                editor.form.default_pair = (pair.provider.clone(), pair.model.clone());
                cx.notify();
            }
        }));

        let mut task_selects = Vec::new();
        for (task, _) in TASKS {
            let mut items: Vec<SharedString> = vec![SAME.into()];
            items.extend(labels.iter().cloned());
            let selected = form.per_task.get(task).and_then(index_of).map(|row| row + 1).unwrap_or(0);
            let select = cx.new(|cx| SelectState::new(items, Some(IndexPath::default().row(selected)), window, cx));
            subscriptions.push(cx.subscribe_in(&select, window, move |this, _, event: &SelectEvent<Vec<SharedString>>, _, cx| {
                let SelectEvent::Confirm(Some(label)) = event else { return };
                if let Stage::Editing(editor) = &mut this.stage {
                    match editor.catalog.reviewed.iter().find(|pair| pair.label() == label.as_ref()) {
                        Some(pair) => editor.form.per_task.insert(task.to_owned(), (pair.provider.clone(), pair.model.clone())),
                        None => editor.form.per_task.remove(task),
                    };
                    cx.notify();
                }
            }));
            task_selects.push((task, select));
        }

        let mut limit_inputs = Vec::new();
        for limit in &LIMITS {
            let value = form.limits.get(limit.key).cloned().unwrap_or_default();
            let input = cx.new(|cx| InputState::new(window, cx).default_value(value).placeholder("Ingen gräns"));
            let key = limit.key;
            subscriptions.push(cx.subscribe_in(&input, window, move |this, input, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change)
                    && let Stage::Editing(editor) = &mut this.stage
                {
                    editor.form.limits.insert(key.to_owned(), input.read(cx).value().to_string());
                    cx.notify();
                }
            }));
            limit_inputs.push((key, input));
        }

        let providers: Vec<SharedString> = PROVIDER_IDS.iter().map(|id| provider_name(id).to_owned().into()).collect();
        let key_provider = cx.new(|cx| SelectState::new(providers, Some(IndexPath::default()), window, cx));
        let key_input = cx.new(|cx| InputState::new(window, cx).masked(true).placeholder("Klistra in nyckeln"));
        Editor { file, catalog, form, default_select, task_selects, limit_inputs, key_provider, key_input, _subscriptions: subscriptions }
    }

    /// Writes the changed settings, then restarts the gateway. The phone notices the new
    /// configuration revision (409 `configuration_changed`) and reads the status again by itself.
    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Stage::Editing(editor) = &self.stage else { return };
        let changes = editor.form.changes(&editor.file);
        if changes.is_empty() || !editor.form.problems(&editor.catalog, &editor.file).is_empty() || self.saving {
            return;
        }
        self.saving = true;
        cx.notify();
        let request = AiForm::request(&changes).to_string().into_bytes();
        let write = operation::run(Command::WriteSettings(SettingsFile::Gateway), Some(request), cx);
        let status = self.status.clone();
        cx.spawn_in(window, async move |this, cx| {
            let written = write.await;
            let restarted = match &written {
                Ok(_) => Some(this.update(cx, |_, cx| operation::run(Command::Unit(UnitAction::Restart, Unit::Gateway), None, cx)).ok()),
                Err(_) => None,
            };
            let restarted = match restarted.flatten() {
                Some(task) => Some(task.await),
                None => None,
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.saving = false;
                let notification = match (written, restarted) {
                    (Err(error), _) => Notification::error(error.to_string()),
                    (Ok(_), Some(Err(error))) => Notification::warning(format!("Sparat, men gatewayen gick inte att starta om: {error}")),
                    _ => Notification::success("Sparat. Gatewayen startades om; telefonen läser in den nya konfigurationen själv."),
                };
                window.push_notification(notification, cx);
                status.update(cx, |status, _| status.request_refresh());
                // Read the file again so the list of changes starts from what is saved.
                this.open_editor(window, cx);
            });
        })
        .detach();
    }

    fn save_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Stage::Editing(editor) = &self.stage else { return };
        let Some(index) = editor.key_provider.read(cx).selected_index(cx).map(|path| path.row) else { return };
        let Some(variable) = PROVIDER_SECRET_KEYS.get(index).copied() else { return };
        let key = editor.key_input.read(cx).value().trim().to_owned();
        if key.is_empty() {
            return;
        }
        let input = editor.key_input.clone();
        // The key goes to the helper on stdin only; the field is cleared at once.
        input.update(cx, |input, cx| input.set_value("", window, cx));
        let task = operation::run(Command::WriteSecret(variable), Some(key.into_bytes()), cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                window.push_notification(match result {
                    Ok(_) => Notification::success(format!("Nyckeln sparades ({variable}). Starta om gatewayen för att använda den.")),
                    Err(error) => Notification::error(error.to_string()),
                }, cx);
                this.open_editor(window, cx);
            });
        })
        .detach();
    }

    /// Real provider traffic, started only by the user: one synthetic Swedish call per task.
    fn try_pair(&mut self, pair: Pair, window: &mut Window, cx: &mut Context<Self>) {
        if self.trying.is_some() {
            return;
        }
        let label = pair.label();
        self.trying = Some(label.clone());
        cx.notify();
        let provider = PROVIDER_IDS.iter().find(|id| **id == pair.provider).copied().unwrap_or("groq");
        let task = operation::run(Command::TrialModel { provider, model: pair.model.clone() }, None, cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.trying = None;
                this.trial = Some(match result {
                    Ok(output) => trial_report(&label, &output),
                    Err(error) => TrialReport { label: label.clone(), passed: false, lines: vec![error.to_string()] },
                });
                // A passed candidate is now selectable; read the list again.
                if this.trial.as_ref().is_some_and(|trial| trial.passed) {
                    this.open_editor(window, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn render_current(&self, cx: &Context<Self>) -> impl IntoElement {
        let status = self.status.read(cx);
        let tasks = status.overview().gateway.as_ref().map(|gateway| gateway.tasks.clone()).unwrap_or_default();
        v_flex()
            .gap_1()
            .text_sm()
            .when(tasks.is_empty(), |list| list.child(div().text_color(cx.theme().muted_foreground).child("Gatewayen svarar inte, så den aktuella modellen syns inte här.")))
            .children(TASKS.iter().filter_map(|(task, label)| {
                let (_, provider, model) = tasks.iter().find(|(name, _, _)| name == task)?;
                Some(h_flex().gap_3().justify_between().child(div().text_color(cx.theme().muted_foreground).child(*label)).child(format!("{} · {model}", provider_name(provider))))
            }))
    }

    fn render_editor(&self, editor: &Editor, cx: &mut Context<Self>) -> impl IntoElement {
        let changes = editor.form.changes(&editor.file);
        let problems = editor.form.problems(&editor.catalog, &editor.file);
        let can_save = !changes.is_empty() && problems.is_empty() && !self.saving;
        let theme = cx.theme().clone();
        let section = |title: &str| div().pt_2().font_semibold().child(title.to_owned());
        let field = |label: &str, control: gpui_kit::AnyElement| {
            v_flex().gap_1().child(div().text_sm().text_color(theme.muted_foreground).child(label.to_owned())).child(control)
        };
        v_flex()
            .gap_3()
            .child(section("Modell"))
            .child(field("Standard för alla uppgifter", Select::new(&editor.default_select).id("ai-default").into_any_element()))
            .children(editor.task_selects.iter().map(|(task, select)| {
                let label = TASKS.iter().find(|(name, _)| name == task).map_or("", |(_, label)| *label);
                field(label, Select::new(select).id(SharedString::from(format!("ai-task-{task}"))).into_any_element())
            }))
            .child(section("Gränser"))
            .child(div().grid().grid_cols(2).gap_3().children(editor.limit_inputs.iter().map(|(key, input)| {
                let limit = LIMITS.iter().find(|limit| limit.key == *key).expect("known limit");
                v_flex()
                    .gap_1()
                    .child(div().text_sm().text_color(theme.muted_foreground).child(limit.label))
                    .child(Input::new(input).id(SharedString::from(format!("limit-{key}"))))
                    .child(div().text_xs().text_color(theme.muted_foreground).child(limit.help))
            })))
            .child(section("Nyckel"))
            .child(
                h_flex()
                    .gap_2()
                    .child(div().w_40().child(Select::new(&editor.key_provider).id("key-provider")))
                    .child(div().flex_1().child(Input::new(&editor.key_input).id("key-input").mask_toggle()))
                    .child(Button::new("save-key").label("Spara nyckel").on_click(cx.listener(|this, _, window, cx| this.save_key(window, cx)))),
            )
            .child(div().text_xs().text_color(theme.muted_foreground).child(format!(
                "Nycklar som finns: {}. Panelen visar och sparar aldrig nycklarna själv.",
                PROVIDER_SECRET_KEYS.iter().map(|key| format!("{key} {}", if editor.file.has_secret(key) { "satt" } else { "saknas" })).collect::<Vec<_>>().join(", ")
            )))
            .child(section("Ändringar"))
            .child(render_changes(&changes, &theme))
            .children(problems.iter().map(|problem| {
                h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(theme.danger)).child(problem.clone())
            }))
            .child(
                h_flex().justify_end().child(
                    Button::new("save-ai")
                        .primary()
                        .label("Spara och starta om")
                        .loading(self.saving)
                        .disabled(!can_save)
                        .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                ),
            )
            .child(section("Prova modellerna"))
            .child(div().text_sm().text_color(theme.muted_foreground).child(
                "Ett kort, påhittat svenskt anrop per uppgift med din nyckel. Det enda som skickar något till en leverantör från panelen. En kandidat som klarar provet blir valbar.",
            ))
            .children(editor.catalog.reviewed.iter().chain(&editor.catalog.candidates).map(|pair| {
                let label = pair.label();
                let id = SharedString::from(format!("try-{}-{}", pair.provider, pair.model));
                let pair_for_click = pair.clone();
                h_flex()
                    .gap_3()
                    .justify_between()
                    .text_sm()
                    .child(v_flex().min_w_0().child(label.clone()).when_some(pair.blocked.clone(), |row, reason| {
                        row.child(div().text_xs().text_color(theme.muted_foreground).child(reason))
                    }))
                    .child(
                        Button::new(id)
                            .small()
                            .label("Prova")
                            .loading(self.trying.as_deref() == Some(label.as_str()))
                            .disabled(self.trying.is_some())
                            .on_click(cx.listener(move |this, _, window, cx| this.try_pair(pair_for_click.clone(), window, cx))),
                    )
            }))
            .when_some(self.trial.as_ref(), |list, trial| {
                list.child(
                    v_flex()
                        .id("trial-report")
                        .test_support()
                        .aria_label(if trial.passed { "Provet godkänt" } else { "Provet underkänt" })
                        .gap_1()
                        .p_3()
                        .rounded(theme.radius)
                        .border_1()
                        .border_color(theme.border)
                        .text_sm()
                        .child(h_flex().gap_2().child(Icon::new(if trial.passed { IconName::CircleCheck } else { IconName::CircleX }).text_color(if trial.passed { theme.success } else { theme.danger }))
                            .child(format!("{}: {}", trial.label, if trial.passed { "godkänt" } else { "underkänt" })))
                        .children(trial.lines.iter().map(|line| div().child(line.clone()))),
                )
            })
    }
}

fn render_changes(changes: &[Change], theme: &gpui_kit::component::Theme) -> impl IntoElement {
    let show = |value: &Option<String>| value.clone().unwrap_or_else(|| "(tomt)".to_owned());
    let summary: SharedString = if changes.is_empty() { "Inga ändringar.".into() } else { format!("{} ändringar", changes.len()).into() };
    v_flex()
        .id("ai-changes")
        .test_support()
        .aria_label(summary.clone())
        .gap_1()
        .text_sm()
        .when(changes.is_empty(), |list| list.child(div().text_color(theme.muted_foreground).child(summary)))
        .children(changes.iter().map(|change| {
            h_flex().gap_2().child(div().font_semibold().child(change.key.clone())).child(show(&change.before)).child("→").child(show(&change.after))
        }))
}

fn trial_report(label: &str, output: &[u8]) -> TrialReport {
    let json: Value = serde_json::from_slice(output).unwrap_or(Value::Null);
    let name = |task: &str| TASKS.iter().find(|(id, _)| *id == task).map_or(task.to_owned(), |(_, label)| (*label).to_owned());
    let lines = json["tasks"].as_array().map(|tasks| {
        tasks.iter().map(|task| {
            let label = name(task["task"].as_str().unwrap_or(""));
            let seconds = task["milliseconds"].as_u64().map_or(String::new(), |ms| format!(", {:.1} s", ms as f64 / 1_000.0));
            if task["ok"] == true {
                format!("{label}: godkänt svar{seconds}")
            } else {
                format!("{label}: {}{seconds}", task["error"].as_str().unwrap_or("fel"))
            }
        }).collect()
    }).unwrap_or_default();
    TrialReport { label: label.to_owned(), passed: json["passed"] == true, lines }
}

impl Render for AiPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body = match &self.stage {
            Stage::Closed => v_flex()
                .gap_3()
                .child(self.render_current(cx))
                .child(h_flex().child(Button::new("edit-ai").label("Ändra…").icon(IconName::Settings).on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Loading => div().text_sm().text_color(cx.theme().muted_foreground).child("Läser inställningarna …").into_any_element(),
            Stage::Failed(message) => v_flex()
                .gap_3()
                .child(h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(cx.theme().danger)).child(message.clone()))
                .child(h_flex().child(Button::new("retry-ai").label("Försök igen").on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Editing(editor) => self.render_editor(editor, cx).into_any_element(),
        };
        v_flex()
            .id("ai")
            .size_full()
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .p_4()
                    .gap_4()
                    .child(v_flex().gap_1().child(div().text_xl().font_semibold().child("AI")).child(
                        div().text_sm().text_color(cx.theme().muted_foreground).child("Vilken granskad modell gatewayen använder, gränserna och nycklarna."),
                    ))
                    .child(body),
            )
    }
}
