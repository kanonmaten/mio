//! AI: which reviewed model each task uses and whether it reasons, this month's credit meter, the
//! gateway's limits, provider keys, and a test call the user starts. Nothing is written before the
//! "före → efter" list has been shown, and the gateway checks the file again before the helper
//! writes it. The meter and the reasoning levels come from `/v2/status` without a password.


use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::collapsible::Collapsible;
use gpui_kit::component::combobox::{Combobox, ComboboxEvent, ComboboxState};
use gpui_kit::component::searchable_list::{SearchableGroup, SearchableListItem, SearchableVec};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::progress::Progress;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::select::{Select, SelectEvent, SelectState};
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, IndexPath, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    App, AppContext as _, Context, Entity, EventEmitter, Focusable as _, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::ai_settings::{AiForm, Catalog, ChoiceKind, GatewayFile, LIMITS, Pair, REASONING_TASK, TASKS, parse_openrouter_models, provider_name, reasoning_level_name};
use mio_control_core::credit::{CreditLevel, CreditMeter, format_limit, parse_limit};
use mio_control_core::command::{Command, PROVIDER_IDS, Unit, UnitAction};
use mio_control_core::settings::{PROVIDER_SECRET_KEYS, SettingsFile};
use serde_json::Value;

use crate::model::StatusModel;
use crate::operation;
use crate::parts::render_changes;

type Choice = SelectState<Vec<SharedString>>;

/// One model in a task's searchable list. Only `Selectable` rows can be chosen; the others are
/// shown so the user sees what exists and what a trial would unlock.
#[derive(Clone)]
struct ModelItem {
    model: SharedString,
    kind: ChoiceKind,
    note: Option<SharedString>,
}

impl SearchableListItem for ModelItem {
    type Value = SharedString;

    fn title(&self) -> SharedString {
        self.model.clone()
    }

    fn value(&self) -> &SharedString {
        &self.model
    }

    fn disabled(&self) -> bool {
        self.kind != ChoiceKind::Selectable
    }

    fn render(&self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        v_flex()
            .child(self.model.clone())
            .when_some(self.note.clone(), |row, note| row.child(div().text_xs().text_color(cx.theme().muted_foreground).child(note)))
    }
}

type ModelList = SearchableVec<SearchableGroup<ModelItem>>;

/// The models `catalog` offers `task` from `provider`, grouped by whether they can be chosen.
fn model_list(catalog: &Catalog, task: &str, provider: &str, openrouter: &[String]) -> ModelList {
    let choices = catalog.model_choices(task, provider, openrouter);
    let groups = [ChoiceKind::Selectable, ChoiceKind::NeedsTrial, ChoiceKind::Unreviewed]
        .into_iter()
        .filter_map(|kind| {
            let items: Vec<ModelItem> = choices
                .iter()
                .filter(|choice| choice.kind == kind)
                .map(|choice| ModelItem { model: choice.model.clone().into(), kind, note: choice.note.clone().map(Into::into) })
                .collect();
            (!items.is_empty()).then(|| SearchableGroup::new(kind.group()).items(items))
        })
        .collect::<Vec<_>>();
    SearchableVec::new(groups)
}

/// A task's two choices: the provider, then one of its models.
struct TaskRow {
    task: &'static str,
    providers: Vec<&'static str>,
    provider: Entity<Choice>,
    model: Entity<ComboboxState<ModelList>>,
}

/// The reasoning select's names and selection for the lesson model.
fn reasoning_items(form: &AiForm, catalog: &Catalog) -> (Vec<SharedString>, Option<IndexPath>) {
    let levels = form.lesson_reasoning_levels(catalog);
    let current = form.lesson_reasoning_level(catalog);
    let names = levels.iter().map(|level| SharedString::from(reasoning_level_name(level).to_owned())).collect();
    let selected = levels.iter().position(|level| Some(level) == current.as_ref()).map(|row| IndexPath::default().row(row));
    (names, selected)
}

/// After the lesson model changed: drop a level it is not reviewed for and offer its levels.
fn refresh_reasoning(editor: &mut Editor, window: &mut Window, cx: &mut App) {
    editor.form.fit_lesson_reasoning(&editor.catalog);
    let (names, selected) = reasoning_items(&editor.form, &editor.catalog);
    editor.reasoning.update(cx, |state, cx| {
        state.set_items(names, window, cx);
        state.set_selected_index(selected, window, cx);
    });
}

/// The editor once settings and model list are read.
struct Editor {
    file: GatewayFile,
    catalog: Catalog,
    form: AiForm,
    rows: Vec<TaskRow>,
    /// The lesson model's reviewed reasoning levels, shown when it has more than one (MIO-44).
    reasoning: Entity<Choice>,
    limit_inputs: Vec<(&'static str, Entity<InputState>)>,
    /// The provider whose key field is open, if any.
    key_editing: Option<&'static str>,
    key_input: Entity<InputState>,
    limits_open: bool,
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

/// Emitted after a key or the settings were written, so the shell can close the other AI
/// view's editor (the AI page and Kom igång's step each hold one) before it shows stale values.
pub struct AiSaved;

pub struct AiPage {
    status: Entity<StatusModel>,
    stage: Stage,
    saving: bool,
    /// "Spara nyckel" is writing through the helper.
    saving_key: bool,
    trying: Option<String>,
    trial: Option<TrialReport>,
    /// OpenRouter's public model IDs, fetched once when the editor first opens.
    openrouter_models: Vec<String>,
    /// The fetch has been started. It is never repeated, even after a failure or an empty
    /// answer: the list is only extra grey rows, not worth a second wait.
    openrouter_requested: bool,
    /// The credit meter's limit, saved in the panel's own preferences.
    credit_limit_cents: u64,
    credit_input: Entity<InputState>,
    credit_input_valid: bool,
    /// Shown inside Kom igång: only the providers, models and trials, scrolled by the guide.
    embedded: bool,
    /// Counts readings of `gateway.env`. A reading that finishes after a newer one started, or
    /// after `forget_editor`, is thrown away, so an old file never becomes the editor again.
    reading: u64,
    _subscriptions: Vec<Subscription>,
}


impl EventEmitter<AiSaved> for AiPage {}

impl AiPage {
    pub fn new(status: Entity<StatusModel>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        let credit_limit_cents = crate::computer::preferences(cx).credit_limit_cents;
        let credit_input = cx.new(|cx| InputState::new(window, cx).default_value(format_limit(credit_limit_cents)).placeholder("20"));
        // A valid amount is saved at once; an invalid one keeps the last saved limit.
        let typed = cx.subscribe_in(&credit_input, window, |this: &mut Self, input, event: &InputEvent, window, cx| {
            if !matches!(event, InputEvent::Change) {
                return;
            }
            let parsed = parse_limit(&input.read(cx).value());
            this.credit_input_valid = parsed.is_some();
            if let Some(cents) = parsed.filter(|cents| *cents != this.credit_limit_cents) {
                this.credit_limit_cents = cents;
                if let Err(message) = crate::computer::save_preferences(|preferences| preferences.credit_limit_cents = cents, cx) {
                    window.push_notification(Notification::error(message), cx);
                }
            }
            cx.notify();
        });
        Self {
            status,
            stage: Stage::Closed,
            saving: false,
            saving_key: false,
            trying: None,
            trial: None,
            openrouter_models: Vec::new(),
            openrouter_requested: false,
            credit_limit_cents,
            credit_input,
            credit_input_valid: true,
            embedded: false,
            reading: 0,
            _subscriptions: vec![observe, typed],
        }
    }

    /// The same editor for Kom igång's AI step. It is its own entity: after either view saves,
    /// the shell makes the other forget what it read (`AiSaved`).
    pub fn embedded(status: Entity<StatusModel>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self { embedded: true, ..Self::new(status, window, cx) }
    }

    /// Drops what the editor read, after the other AI view saved: "Ändra…" reads the file again.
    /// Nothing is read here, so no password prompt appears for a view that is not on screen.
    pub fn forget_editor(&mut self, cx: &mut Context<Self>) {
        // A reading still on its way may have started before the other view saved.
        self.reading += 1;
        if !matches!(self.stage, Stage::Closed) {
            self.stage = Stage::Closed;
            self.trial = None;
            cx.notify();
        }
    }

    /// Reads `gateway.env` through the helper (KDE asks for the password once) and the model list.
    pub fn open_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.stage = Stage::Loading;
        self.reading += 1;
        let reading = self.reading;
        cx.notify();
        let settings = operation::run(Command::ReadSettings(SettingsFile::Gateway), None, cx);
        let catalog = operation::catalog(cx);
        if !self.openrouter_requested {
            self.openrouter_requested = true;
            self.fetch_openrouter_models(window, cx);
        }
        cx.spawn_in(window, async move |this, cx| {
            let (settings, catalog) = (settings.await, catalog.await);
            let _ = this.update_in(cx, |this, window, cx| {
                if this.reading != reading {
                    return;
                }
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

    /// Fetches OpenRouter's public list in the background; the editor never waits for it. When
    /// it arrives, the rows that show OpenRouter get its unreviewed models.
    fn fetch_openrouter_models(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let task = operation::openrouter_models(cx);
        cx.spawn_in(window, async move |this, cx| {
            let models = task.await.ok().and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok()).map(|json| parse_openrouter_models(&json));
            let Some(models) = models.filter(|models| !models.is_empty()) else { return };
            let _ = this.update_in(cx, |this, window, cx| {
                this.openrouter_models = models;
                let Stage::Editing(editor) = &this.stage else { return };
                for row in &editor.rows {
                    let (provider, model) = editor.form.pair_for(row.task).clone();
                    if provider != "openrouter" {
                        continue;
                    }
                    let list = model_list(&editor.catalog, row.task, &provider, &this.openrouter_models);
                    row.model.update(cx, |state, cx| {
                        state.set_items(list, window, cx);
                        state.set_selected_values(&[SharedString::from(model)], window, cx);
                    });
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn build_editor(&mut self, file: GatewayFile, catalog: Catalog, window: &mut Window, cx: &mut Context<Self>) -> Editor {
        // A candidate that passed "Prova" is listed in the file the helper just read, so it is
        // offered here at once, without restarting the panel.
        let catalog = catalog.with_approved(&file);
        let mut form = AiForm::from_file(&file);
        // A level the lesson model is not reviewed for (left from another model) goes back to the
        // model's own at once, so the select shows what runs and the preview shows the removal.
        form.fit_lesson_reasoning(&catalog);
        let mut subscriptions = Vec::new();

        // One row per task. Each select offers only what may serve that task: a pair reviewed
        // for lessons only (it reasons) is never listed for Frågor or Vardag.
        let mut rows = Vec::new();
        for (task, _) in TASKS {
            let (current_provider, current_model) = form.pair_for(task).clone();
            let mut providers = catalog.providers_for(task, &PROVIDER_IDS);
            // A provider the file names but the catalog no longer offers still shows, so the
            // problem list can say what is wrong with it.
            if let Some(known) = PROVIDER_IDS.iter().copied().find(|id| *id == current_provider)
                && !providers.contains(&known)
            {
                providers.push(known);
            }
            let names: Vec<SharedString> = providers.iter().map(|id| provider_name(id).to_owned().into()).collect();
            let selected = providers.iter().position(|id| *id == current_provider).map(|row| IndexPath::default().row(row));
            let provider = cx.new(|cx| SelectState::new(names, selected, window, cx));
            let list = model_list(&catalog, task, &current_provider, &self.openrouter_models);
            let model = cx.new(|cx| {
                let mut state = ComboboxState::new(list, Vec::new(), window, cx).searchable(true);
                state.set_selected_values(&[SharedString::from(current_model.clone())], window, cx);
                state
            });

            subscriptions.push(cx.subscribe_in(&provider, window, move |this, _, event: &SelectEvent<Vec<SharedString>>, window, cx| {
                let SelectEvent::Confirm(Some(label)) = event else { return };
                let openrouter = this.openrouter_models.clone();
                let Stage::Editing(editor) = &mut this.stage else { return };
                let Some(row) = editor.rows.iter().find(|row| row.task == task) else { return };
                let Some(chosen) = row.providers.iter().copied().find(|id| provider_name(id) == label.as_ref()) else { return };
                if editor.form.pair_for(task).0 == chosen {
                    return;
                }
                // The first model this provider may serve the task with, or none until a trial
                // passes; then the problem list asks for one.
                let model = editor.catalog.first_choice(task, chosen).map(|pair| pair.model.clone()).unwrap_or_default();
                editor.form.set_task(task, (chosen.to_owned(), model.clone()));
                let list = model_list(&editor.catalog, task, chosen, &openrouter);
                row.model.update(cx, |state, cx| {
                    state.set_items(list, window, cx);
                    state.set_selected_values(&[SharedString::from(model)], window, cx);
                });
                if task == REASONING_TASK {
                    refresh_reasoning(editor, window, cx);
                }
                cx.notify();
            }));
            subscriptions.push(cx.subscribe_in(&model, window, move |this, _, event: &ComboboxEvent<ModelList>, window, cx| {
                let ComboboxEvent::Confirm(values) = event else { return };
                let Some(model) = values.first() else { return };
                let Stage::Editing(editor) = &mut this.stage else { return };
                let provider = editor.form.pair_for(task).0.clone();
                // Only a selectable row can be confirmed; the check keeps the form honest anyway.
                if editor.catalog.find(&provider, model).is_some_and(|pair| pair.allows(task)) {
                    editor.form.set_task(task, (provider, model.to_string()));
                    if task == REASONING_TASK {
                        refresh_reasoning(editor, window, cx);
                    }
                    cx.notify();
                }
            }));
            rows.push(TaskRow { task, providers, provider, model });
        }

        let (names, selected) = reasoning_items(&form, &catalog);
        let reasoning = cx.new(|cx| SelectState::new(names, selected, window, cx));
        subscriptions.push(cx.subscribe_in(&reasoning, window, |this, _, event: &SelectEvent<Vec<SharedString>>, _, cx| {
            let SelectEvent::Confirm(Some(label)) = event else { return };
            let Stage::Editing(editor) = &mut this.stage else { return };
            let chosen = editor.form.lesson_reasoning_levels(&editor.catalog).iter()
                .find(|level| reasoning_level_name(level) == label.as_ref()).cloned();
            if let Some(level) = chosen {
                editor.form.lesson_reasoning = level;
                cx.notify();
            }
        }));

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

        let key_input = cx.new(|cx| InputState::new(window, cx).masked(true).placeholder("Klistra in nyckeln"));
        Editor { file, catalog, form, rows, reasoning, limit_inputs, key_editing: None, key_input, limits_open: false, _subscriptions: subscriptions }
    }

    /// The lesson model's reasoning level under the lesson row: a select when more than one level
    /// is reviewed, a line when only one is, nothing when the model does not reason.
    fn render_reasoning(&self, editor: &Editor, cx: &Context<Self>) -> Option<gpui_kit::AnyElement> {
        let levels = editor.form.lesson_reasoning_levels(&editor.catalog);
        let current = editor.form.lesson_reasoning_level(&editor.catalog)?;
        let theme = cx.theme();
        let row = h_flex().gap_3().child(div().w_24().text_sm().text_color(theme.muted_foreground).child("Resonemang"));
        Some(if levels.len() > 1 {
            row.child(div().w_40().child(Select::new(&editor.reasoning).id("ai-reasoning-lesson")))
                .child(div().flex_1().min_w_0().text_sm().text_color(theme.muted_foreground)
                    .child("Högre nivå tänker längre: bättre anteckningar, men dyrare och långsammare. Tänkandet räknas in i svarslängden, så Hög kan behöva en längre svarslängd för Lektioner under Gränser. Prova provar på nivån du sparat."))
                .into_any_element()
        } else {
            row.child(div().id("ai-reasoning-lesson").test_support().flex_1().text_sm().text_color(theme.muted_foreground)
                .child(format!("{}, den enda nivå som är granskad för modellen.", reasoning_level_name(&current))))
                .into_any_element()
        })
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
                if written.is_ok() {
                    cx.emit(AiSaved);
                }
                let notification = match (written, restarted) {
                    (Err(error), _) => Notification::error(error.to_string()),
                    (Ok(_), Some(Err(error))) => Notification::warning(format!("Sparat, men gatewayen gick inte att starta om: {error}")),
                    _ => Notification::success("Sparat. Gatewayen startades om; telefonen läser in den nya konfigurationen själv."),
                };
                window.push_notification(notification, cx);
                status.update(cx, |status, cx| status.request_refresh(cx));
                // Read the file again so the list of changes starts from what is saved.
                this.open_editor(window, cx);
            });
        })
        .detach();
    }

    fn save_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Stage::Editing(editor) = &self.stage else { return };
        let Some(provider) = editor.key_editing else { return };
        // PROVIDER_IDS and PROVIDER_SECRET_KEYS list the providers in the same order.
        let Some(variable) = PROVIDER_IDS.iter().position(|id| *id == provider).and_then(|index| PROVIDER_SECRET_KEYS.get(index)).copied() else { return };
        let key = editor.key_input.read(cx).value().trim().to_owned();
        if key.is_empty() {
            return;
        }
        let input = editor.key_input.clone();
        // The key goes to the helper on stdin only; the field is cleared at once.
        input.update(cx, |input, cx| input.set_value("", window, cx));
        self.saving_key = true;
        cx.notify();
        let task = operation::run(Command::WriteSecret(variable), Some(key.into_bytes()), cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.saving_key = false;
                if let (Ok(_), Stage::Editing(editor)) = (&result, &mut this.stage) {
                    editor.key_editing = None;
                }
                if result.is_ok() {
                    cx.emit(AiSaved);
                }
                window.push_notification(match result {
                    Ok(_) => Notification::success(format!("Nyckeln för {} sparades. Den används när gatewayen startas om, till exempel med Spara och starta om.", provider_name(provider))),
                    Err(error) => Notification::error(error.to_string()),
                }, cx);
                this.open_editor(window, cx);
            });
        })
        .detach();
    }

    /// Real provider traffic, started only by the user: one synthetic Swedish call per task the
    /// pair may serve.
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
                // A passed candidate is now in `MIO_APPROVED_CANDIDATES`; reading the file again
                // makes it selectable (`Catalog::with_approved`).
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
                let status = tasks.iter().find(|status| status.task == *task)?;
                let reasoning = status.reasoning_label();
                Some(
                    h_flex()
                        .gap_3()
                        .justify_between()
                        .child(div().text_color(cx.theme().muted_foreground).child(*label))
                        .child(
                            h_flex()
                                .gap_2()
                                .child(format!("{} · {}", provider_name(&status.provider), status.model))
                                // An older gateway does not say; then nothing is shown.
                                .when_some(reasoning, |row, reasoning| {
                                    row.child(
                                        div()
                                            .id(SharedString::from(format!("reasoning-{task}")))
                                            .test_support()
                                            .aria_label(SharedString::from(reasoning.clone()))
                                            .text_color(cx.theme().muted_foreground)
                                            .child(format!("· {reasoning}")),
                                    )
                                }),
                        ),
                )
            }))
            .when(tasks.iter().any(|status| status.reasoning.is_some()), |list| {
                list.child(div().text_xs().text_color(cx.theme().muted_foreground).child(
                    "Bara Lektioner får resonera. En modell som resonerar går bara att välja för Lektioner; gatewayen vägrar starta annars.",
                ))
            })
    }

    /// This month's tokens and estimated cost per task and model against the user's limit.
    fn render_credit(&self, cx: &Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let muted = |text: &str| div().text_sm().text_color(theme.muted_foreground).child(text.to_owned());
        let gateway = self.status.read(cx).overview().gateway.clone();
        let meter = gateway.as_ref().and_then(|gateway| gateway.usage.as_ref()).map(|usage| CreditMeter::new(usage, self.credit_limit_cents));
        let limit_field = v_flex()
            .gap_1()
            .child(
                h_flex()
                    .gap_2()
                    .text_sm()
                    .child(div().text_color(theme.muted_foreground).child("Kreditgräns i dollar per månad"))
                    .child(div().w_24().child(Input::new(&self.credit_input).id("credit-limit").small())),
            )
            .when(!self.credit_input_valid, |field| {
                field.child(h_flex().gap_2().text_xs().child(Icon::new(IconName::CircleX).text_color(theme.danger)).child(format!(
                    "Skriv ett belopp i dollar, till exempel 20. Gränsen är kvar på ${}.",
                    format_limit(self.credit_limit_cents)
                )))
            });
        let body = match (&gateway, meter) {
            (None, _) => muted("Gatewayen svarar inte, så månadens användning syns inte här.").into_any_element(),
            (Some(_), None) => muted("Gatewayen redovisar ingen användning. Den är äldre än kreditmätaren eller kan inte läsa sin räknarfil.").into_any_element(),
            (Some(_), Some(meter)) => {
                let (icon, color) = match meter.level {
                    CreditLevel::Normal => (IconName::CircleCheck, theme.success),
                    CreditLevel::Warning => (IconName::TriangleAlert, theme.warning),
                    CreditLevel::Over => (IconName::CircleX, theme.danger),
                };
                let summary = SharedString::from(format!("{}. {}", meter.level_label(), meter.summary()));
                v_flex()
                    .gap_2()
                    .child(
                        h_flex()
                            .id("credit-meter")
                            .test_support()
                            .aria_label(summary.clone())
                            .gap_2()
                            .text_sm()
                            .child(Icon::new(icon).text_color(color))
                            .child(summary),
                    )
                    .child(Progress::new("credit-bar").value(meter.percent()).when(meter.level != CreditLevel::Normal, |bar| bar.color(color)))
                    .when(meter.rows.is_empty(), |list| list.child(muted("Inga anrop än den här månaden.")))
                    .children(meter.rows.iter().map(|row| {
                        h_flex()
                            .gap_3()
                            .text_sm()
                            .child(div().w_24().text_color(theme.muted_foreground).child(row.task.clone()))
                            .child(div().flex_1().min_w_0().child(row.pair.clone()))
                            .child(div().text_color(theme.muted_foreground).child(row.tokens.clone()))
                            .child(div().w_20().text_right().child(row.cost.clone()))
                    }))
                    .child(muted("Uppskattat med gatewayens granskade priser. Leverantörens faktura gäller; gratisnivåer saknar pris."))
                    .into_any_element()
            }
        };
        v_flex().gap_2().child(div().font_semibold().child("Kreditmätaren")).child(body).child(limit_field)
    }

    fn render_editor(&self, editor: &Editor, cx: &mut Context<Self>) -> impl IntoElement {
        let changes = editor.form.changes(&editor.file);
        let problems = editor.form.problems(&editor.catalog, &editor.file);
        let can_save = !changes.is_empty() && problems.is_empty() && !self.saving;
        let theme = cx.theme().clone();
        let section = |title: &str| div().pt_2().font_semibold().child(title.to_owned());
        let muted = |text: String| div().text_sm().text_color(theme.muted_foreground).child(text);
        let mut provider_rows = Vec::new();
        for (provider, variable) in PROVIDER_IDS.iter().zip(PROVIDER_SECRET_KEYS) {
            provider_rows.push(self.render_provider(editor, provider, variable, cx));
        }
        let mut trial_rows = Vec::new();
        for pair in editor.catalog.trial_order() {
            trial_rows.push(self.render_trial_row(editor, pair, cx));
        }
        v_flex()
            .gap_3()
            .child(section("Leverantörer"))
            .child(muted("En nyckel per leverantör. Panelen visar aldrig nycklarna; de sparas i gatewayens fil som bara root kan läsa.".into()))
            .children(provider_rows)
            .child(section("Modell per uppgift"))
            .child(muted("Välj leverantör och sedan modell. Gråa modeller kräver ett godkänt prov eller är inte granskade än.".into()))
            .children(editor.rows.iter().map(|row| {
                let label = TASKS.iter().find(|(name, _)| *name == row.task).map_or("", |(_, label)| *label);
                let task_row = h_flex()
                    .gap_3()
                    .child(div().w_24().text_sm().text_color(theme.muted_foreground).child(label))
                    .child(div().w_40().child(Select::new(&row.provider).id(SharedString::from(format!("ai-provider-{}", row.task)))))
                    .child(
                        div()
                            .id(SharedString::from(format!("ai-model-{}", row.task)))
                            .test_support()
                            .flex_1()
                            .min_w_0()
                            .child(Combobox::new(&row.model).placeholder("Välj modell").search_placeholder("Sök modell")),
                    );
                let reasoning = (row.task == REASONING_TASK).then(|| self.render_reasoning(editor, cx)).flatten();
                v_flex().gap_2().child(task_row).children(reasoning)
            }))
            .child(section("Prova modellerna"))
            .child(muted(
                "Ett kort, påhittat svenskt anrop per uppgift som paret får användas till, med din nyckel, till leverantören som står vid modellen. Det enda som skickar något till en leverantör från panelen, och det kostar som vanliga anrop. En kandidat som klarar provet blir valbar.".into(),
            ))
            .children(trial_rows)
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
            .child(
                h_flex().pt_2().child(
                    Button::new("toggle-limits")
                        .ghost()
                        .label("Gränser")
                        .icon(if editor.limits_open { IconName::ChevronDown } else { IconName::ChevronRight })
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Stage::Editing(editor) = &mut this.stage {
                                editor.limits_open = !editor.limits_open;
                                cx.notify();
                            }
                        })),
                ),
            )
            .child(Collapsible::new().open(editor.limits_open).content(div().grid().grid_cols(2).gap_3().children(editor.limit_inputs.iter().map(|(key, input)| {
                let limit = LIMITS.iter().find(|limit| limit.key == *key).expect("known limit");
                v_flex()
                    .gap_1()
                    .child(div().text_sm().text_color(theme.muted_foreground).child(limit.label))
                    .child(Input::new(input).id(SharedString::from(format!("limit-{key}"))))
                    .child(div().text_xs().text_color(theme.muted_foreground).child(limit.help))
            }))))
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
                        .disabled(!can_save || self.saving)
                        .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                ),
            )
    }

    /// A provider and whether its key is saved; the key field opens in the row itself.
    fn render_provider(&self, editor: &Editor, provider: &'static str, variable: &str, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let theme = cx.theme().clone();
        let saved = editor.file.has_secret(variable);
        let editing = editor.key_editing == Some(provider);
        let state = if saved { "Nyckel sparad" } else { "Ingen nyckel" };
        h_flex()
            .id(SharedString::from(format!("provider-{provider}")))
            .test_support()
            .aria_label(SharedString::from(format!("{}: {state}", provider_name(provider))))
            .gap_3()
            .text_sm()
            .child(div().w_24().child(provider_name(provider).to_owned()))
            .child(
                h_flex()
                    .w_32()
                    .gap_2()
                    .child(Icon::new(if saved { IconName::CircleCheck } else { IconName::CircleAlert }).text_color(if saved { theme.success } else { theme.muted_foreground }))
                    .child(div().text_color(theme.muted_foreground).child(state)),
            )
            .map(|row| {
                if editing {
                    row.child(div().flex_1().min_w_0().child(Input::new(&editor.key_input).id("key-input").mask_toggle()))
                        .child(
                            Button::new("save-key")
                                .primary()
                                .small()
                                .label("Spara nyckel")
                                .loading(self.saving_key)
                                .disabled(self.saving_key)
                                .on_click(cx.listener(|this, _, window, cx| this.save_key(window, cx))),
                        )
                        .child(Button::new("cancel-key").ghost().small().label("Avbryt").disabled(self.saving_key).on_click(cx.listener(|this, _, window, cx| {
                            if let Stage::Editing(editor) = &mut this.stage {
                                editor.key_editing = None;
                                editor.key_input.update(cx, |input, cx| input.set_value("", window, cx));
                                cx.notify();
                            }
                        })))
                } else {
                    row.child(div().flex_1()).child(
                        Button::new(SharedString::from(format!("key-edit-{provider}")))
                            .outline()
                            .small()
                            .label(if saved { "Byt nyckel…" } else { "Lägg till nyckel…" })
                            .disabled(self.saving_key)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if let Stage::Editing(editor) = &mut this.stage {
                                    editor.key_editing = Some(provider);
                                    editor.key_input.update(cx, |input, cx| input.set_value("", window, cx));
                                    editor.key_input.read(cx).focus_handle(cx).focus(window, cx);
                                    cx.notify();
                                }
                            })),
                    )
                }
            })
            .into_any_element()
    }

    /// One pair "Prova" can send a test call for. Without the provider's key the call cannot
    /// succeed, so the button says why instead of sending it.
    fn render_trial_row(&self, editor: &Editor, pair: &Pair, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let theme = cx.theme().clone();
        let label = pair.label();
        let id = SharedString::from(format!("try-{}-{}", pair.provider, pair.model));
        // Prova sends what is saved, not what is typed, so the estimate reads the file.
        let saved = AiForm::from_file(&editor.file);
        let estimate = SharedString::from(pair.trial_estimate(|task| saved.output_tokens(task)));
        let has_key = editor.file.has_secret(&pair.secret_variable);
        let pair_for_click = pair.clone();
        h_flex()
            .gap_3()
            .justify_between()
            .text_sm()
            .child(
                v_flex()
                    .min_w_0()
                    .child(label.clone())
                    .when_some(pair.note(), |row, note| row.child(div().text_xs().text_color(theme.muted_foreground).child(note)))
                    .when_some(pair.blocked.clone(), |row, reason| row.child(div().text_xs().text_color(theme.muted_foreground).child(reason)))
                    .when(!has_key, |row| {
                        row.child(div().text_xs().text_color(theme.muted_foreground).child(format!("Lägg till en nyckel för {} först.", provider_name(&pair.provider))))
                    })
                    .child(
                        div()
                            .id(SharedString::from(format!("trial-cost-{}-{}", pair.provider, pair.model)))
                            .test_support()
                            .aria_label(estimate.clone())
                            .text_xs()
                            .text_color(theme.muted_foreground)
                            .child(estimate),
                    ),
            )
            .child(
                Button::new(id)
                    .small()
                    .label("Prova")
                    .loading(self.trying.as_deref() == Some(label.as_str()))
                    .disabled(self.trying.is_some() || !has_key)
                    .on_click(cx.listener(move |this, _, window, cx| this.try_pair(pair_for_click.clone(), window, cx))),
            )
            .into_any_element()
    }
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
        let edit_label = if self.embedded { "Välj leverantör och modell…" } else { "Ändra…" };
        let body = match &self.stage {
            Stage::Closed => v_flex()
                .gap_3()
                .when(!self.embedded, |body| body.child(self.render_current(cx)))
                .child(h_flex().child(Button::new("edit-ai").label(edit_label).icon(IconName::Settings).on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Loading => crate::parts::loading_line("Läser inställningarna …", cx).into_any_element(),
            Stage::Failed(message) => v_flex()
                .gap_3()
                .child(h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(cx.theme().danger)).child(message.clone()))
                .child(h_flex().child(Button::new("retry-ai").label("Försök igen").on_click(cx.listener(|this, _, window, cx| this.open_editor(window, cx)))))
                .into_any_element(),
            Stage::Editing(editor) => self.render_editor(editor, cx).into_any_element(),
        };
        if self.embedded {
            return v_flex().id("setup-ai").test_support().child(body).into_any_element();
        }
        v_flex()
            .id("ai")
            .size_full()
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .p_4()
                    .gap_4()
                    .child(v_flex().gap_1().child(div().text_xl().font_semibold().child("AI")).child(
                        div().text_sm().text_color(cx.theme().muted_foreground).child("Vilken granskad modell gatewayen använder, vad den kostar i månaden, gränserna och nycklarna."),
                    ))
                    .child(self.render_credit(cx))
                    .child(body),
            )
            .into_any_element()
    }
}
