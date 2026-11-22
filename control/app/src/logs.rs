//! Loggar: the journal per service, with a level filter and a follow mode that reads what is new
//! every two seconds.

use std::sync::Arc;
use std::time::Duration;

use gpui_kit::component::radio::RadioGroup;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{ActiveTheme as _, Icon, IconName, h_flex, v_flex};
use gpui_kit::{
    App, Context, Global, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Task, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::format::{ago, now_seconds};
use mio_control_core::journal::{Entry, Level, LogUnit, MAX_LINES, Read, read};

use crate::parts::page_header;

const FOLLOW_EVERY: Duration = Duration::from_secs(2);

pub type ReadFn = Arc<dyn Fn(LogUnit, Option<String>) -> Result<Read, String> + Send + Sync>;

#[derive(Clone)]
pub struct LogBackend {
    pub read: ReadFn,
}

impl Global for LogBackend {}

impl LogBackend {
    pub fn system() -> Self {
        Self { read: Arc::new(|unit, after| read(unit, after.as_deref())) }
    }
}

fn backend(cx: &App) -> LogBackend {
    cx.try_global::<LogBackend>().cloned().unwrap_or_else(LogBackend::system)
}

pub struct LogsPage {
    unit: LogUnit,
    level: Level,
    entries: Vec<Entry>,
    problem: Option<SharedString>,
    loaded: bool,
    loading: Option<Task<()>>,
    follow: Option<Task<()>>,
}

impl LogsPage {
    pub fn new() -> Self {
        Self { unit: LogUnit::Gateway, level: Level::Info, entries: Vec::new(), problem: None, loaded: false, loading: None, follow: None }
    }

    pub fn load_once(&mut self, cx: &mut Context<Self>) {
        if !self.loaded && self.loading.is_none() {
            self.load(cx);
        }
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let (read, unit) = (backend(cx).read, self.unit);
        let task = cx.background_executor().spawn(async move { read(unit, None) });
        self.loading = Some(cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.loading = None;
                this.loaded = true;
                match result {
                    Ok(read) => {
                        this.entries = read.entries;
                        this.problem = read.hint.map(Into::into);
                    }
                    Err(message) => {
                        this.entries.clear();
                        this.problem = Some(message.into());
                    }
                }
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn set_follow(&mut self, on: bool, cx: &mut Context<Self>) {
        // Dropping the task stops the polling.
        self.follow = on.then(|| {
            cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor().timer(FOLLOW_EVERY).await;
                    let Ok((read, unit, after)) = this.update(cx, |this, cx| (backend(cx).read, this.unit, this.entries.last().map(|entry| entry.cursor.clone()))) else {
                        return;
                    };
                    let result = cx.background_executor().spawn(async move { read(unit, after) }).await;
                    let Ok(()) = this.update(cx, |this, cx| {
                        if let Ok(read) = result
                            && !read.entries.is_empty()
                        {
                            this.entries.extend(read.entries);
                            if this.entries.len() > MAX_LINES {
                                this.entries.drain(..this.entries.len() - MAX_LINES);
                            }
                            cx.notify();
                        }
                    }) else {
                        return;
                    };
                }
            })
        });
        cx.notify();
    }
}

impl Default for LogsPage {
    fn default() -> Self {
        Self::new()
    }
}

impl Render for LogsPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let now = now_seconds();
        let shown: Vec<&Entry> = self.entries.iter().filter(|entry| self.level.shows(entry.priority)).collect();
        let count: SharedString = format!("{} rader", shown.len()).into();
        let lines = shown.iter().rev().map(|entry| {
            let color = match entry.priority {
                0..=3 => theme.danger,
                4 => theme.warning,
                _ => theme.foreground,
            };
            h_flex().gap_3().items_start()
                .child(div().w_24().flex_none().text_color(theme.muted_foreground).child(ago(entry.time, now)))
                .child(div().flex_1().min_w_0().text_color(color).child(entry.message.clone()))
        });
        v_flex().id("logs").size_full().p_4().gap_3()
            .child(page_header("Loggar", "Journalen för Mios tjänster, nyast överst. Tjänsterna loggar aldrig text, nycklar eller egna ord.", cx))
            .child(RadioGroup::horizontal("log-unit")
                .children(LogUnit::ALL.map(LogUnit::title))
                .selected_index(LogUnit::ALL.iter().position(|unit| *unit == self.unit))
                .on_change(cx.listener(|this, index: &usize, _, cx| {
                    this.unit = LogUnit::ALL[*index];
                    this.entries.clear();
                    this.load(cx);
                })))
            .child(h_flex().gap_4().flex_wrap()
                .child(RadioGroup::horizontal("log-level")
                    .children(Level::ALL.map(Level::title))
                    .selected_index(Level::ALL.iter().position(|level| *level == self.level))
                    .on_change(cx.listener(|this, index: &usize, _, cx| {
                        this.level = Level::ALL[*index];
                        cx.notify();
                    })))
                .child(Switch::new("follow").label("Följ").checked(self.follow.is_some())
                    .on_change(cx.listener(|this, on: &bool, _, cx| this.set_follow(*on, cx)))))
            .when_some(self.problem.clone(), |page, problem| page.child(h_flex().gap_2().text_sm()
                .child(Icon::new(IconName::TriangleAlert).text_color(theme.warning)).child(problem)))
            .child(div().id("log-count").test_support().aria_label(count.clone()).text_xs().text_color(theme.muted_foreground)
                .when(self.loading.is_some(), |line| line.child(crate::parts::loading_line("Läser …", cx)))
                .when(self.loading.is_none(), |line| line.child(count)))
            .child(v_flex().id("log-lines").flex_1().min_h_0().overflow_y_scrollbar().gap_1().p_2().rounded(theme.radius)
                .bg(theme.muted).font_family("monospace").text_xs().children(lines))
    }
}
