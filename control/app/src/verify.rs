//! Verifiering: runs `mio-verify verify` in the repo the panel was built from, shows its output as
//! it comes and the gates from the receipt afterwards.

use std::sync::Arc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, Sizable as _, StyledExt as _, h_flex, v_flex};
use gpui_kit::{
    App, Context, Global, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Task, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::updates::built_from;
use mio_control_core::verification::{Receipt, logs_dir, run_streaming, verify_command};

use crate::parts::{page_header, section};

/// Lines of output kept on screen; the full logs are in the logs folder.
const KEPT_LINES: usize = 400;

pub type RunFn = Arc<dyn Fn(&mut dyn FnMut(String)) -> Result<bool, String> + Send + Sync>;

#[derive(Clone)]
pub struct VerifyBackend {
    pub run: RunFn,
    pub receipt: Arc<dyn Fn() -> Option<Receipt> + Send + Sync>,
}

impl Global for VerifyBackend {}

impl VerifyBackend {
    pub fn system() -> Self {
        Self {
            run: Arc::new(|line| {
                let logs = logs_dir().ok_or_else(|| "Hittar ingen hemkatalog för loggarna.".to_owned())?;
                std::fs::create_dir_all(&logs).map_err(|_| format!("Kunde inte skapa {}.", logs.display()))?;
                run_streaming(verify_command(&built_from(), &logs), line)
            }),
            receipt: Arc::new(Receipt::latest),
        }
    }
}

fn backend(cx: &App) -> VerifyBackend {
    cx.try_global::<VerifyBackend>().cloned().unwrap_or_else(VerifyBackend::system)
}

pub struct VerifyPage {
    output: Vec<SharedString>,
    running: Option<Task<()>>,
    finished: Option<Result<bool, String>>,
    receipt: Option<Receipt>,
}

impl VerifyPage {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self { output: Vec::new(), running: None, finished: None, receipt: (backend(cx).receipt)() }
    }

    fn start(&mut self, cx: &mut Context<Self>) {
        if self.running.is_some() {
            return;
        }
        let backend = backend(cx);
        let (sender, lines) = async_channel::unbounded::<String>();
        let run = backend.run.clone();
        let work = cx.background_executor().spawn(async move {
            // The sender is dropped when the run ends, which ends the loop below.
            run(&mut |line| {
                let _ = sender.send_blocking(line);
            })
        });
        self.output.clear();
        self.finished = None;
        self.running = Some(cx.spawn(async move |this, cx| {
            while let Ok(line) = lines.recv().await {
                let Ok(()) = this.update(cx, |this, cx| {
                    this.output.push(line.into());
                    if this.output.len() > KEPT_LINES {
                        this.output.drain(..this.output.len() - KEPT_LINES);
                    }
                    cx.notify();
                }) else {
                    return;
                };
            }
            let result = work.await;
            let _ = this.update(cx, |this, cx| {
                this.finished = Some(result);
                this.receipt = (backend.receipt)();
                this.running = None;
                cx.notify();
            });
        }));
        cx.notify();
    }
}

fn gate_tag(result: &str) -> Tag {
    match result {
        "PASS" => Tag::success(),
        "FAIL" => Tag::danger(),
        _ => Tag::secondary(),
    }
    .child(result.to_owned())
    .small()
}

impl Render for VerifyPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let running = self.running.is_some();
        let summary: Option<(IconName, gpui_kit::Hsla, String)> = match &self.finished {
            None => None,
            Some(Ok(true)) => Some((IconName::CircleCheck, theme.success, "Alla grindar som går att köra här gick igenom.".into())),
            Some(Ok(false)) => Some((IconName::CircleX, theme.danger, "Någon grind misslyckades. Se raden med FAIL och dess logg.".into())),
            Some(Err(message)) => Some((IconName::CircleX, theme.danger, message.clone())),
        };
        let logs = logs_dir().map(|path| path.display().to_string()).unwrap_or_default();
        v_flex().id("verify").size_full().overflow_y_scrollbar().p_4().gap_4()
            .child(page_header("Verifiering", "Kör samma grind som GitHub kör på varje commit (mio-verify verify), här på datorn. Det tar 5–20 minuter.", cx))
            .child(h_flex().gap_2().child(Button::new("run-verify").primary().label("Kör verifieringen").icon(IconName::CircleCheck)
                .loading(running).disabled(running).on_click(cx.listener(|this, _, _, cx| this.start(cx)))))
            .when_some(summary, |page, (icon, color, text)| page.child(h_flex().id("verify-result").test_support().aria_label(text.clone())
                .gap_2().text_sm().child(Icon::new(icon).text_color(color)).child(text)))
            .when(!self.output.is_empty(), |page| page.child(section("Utskrift")).child(
                // The id sits on a wrapper: the scrollbar wraps its element and hides the id.
                div().id("verify-output").test_support().aria_label(format!("{} rader", self.output.len())).child(
                    v_flex().id("verify-output-lines").max_h_80().overflow_y_scrollbar().p_2().rounded(theme.radius).bg(theme.muted)
                        .font_family("monospace").text_xs().children(self.output.iter().map(|line| div().child(line.clone()))))))
            .child(section("Senaste kvittot"))
            .child(match &self.receipt {
                None => div().text_sm().text_color(theme.muted_foreground).child("Verifieringen har inte körts från panelen än.").into_any_element(),
                Some(receipt) => v_flex().id("receipt").test_support().aria_label(receipt.result.clone()).gap_1()
                    .child(h_flex().gap_2().text_sm()
                        .child(div().font_semibold().child(receipt.result.clone()))
                        .when_some(receipt.commit.clone(), |row, commit| row.child(div().text_color(theme.muted_foreground)
                            .child(format!("commit {}{}", commit.chars().take(7).collect::<String>(), if receipt.dirty { " med osparade ändringar" } else { "" }))))
                        .when_some(receipt.finished_at.clone(), |row, at| row.child(div().text_color(theme.muted_foreground).child(at))))
                    .children(receipt.gates.iter().map(|gate| h_flex().gap_2().text_sm()
                        .child(gate_tag(&gate.result))
                        .child(div().flex_1().child(gate.gate.clone()))
                        .child(div().text_color(theme.muted_foreground).child(gate.seconds.clone().unwrap_or_default()))))
                    .child(div().pt_1().text_xs().text_color(theme.muted_foreground).child(format!("Loggarna ligger i {logs}.")))
                    .into_any_element(),
            })
    }
}
