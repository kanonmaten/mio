//! Small pieces several pages share.

use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{ActiveTheme as _, Sizable as _, StyledExt as _, Theme, h_flex, v_flex};
use gpui_kit::{
    App, InteractiveElement as _, IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    TestSupportExt as _, div, prelude::FluentBuilder as _,
};
use mio_control_core::ai_settings::Change;

/// The "före → efter" list shown before anything is saved. Its accessible name says how many.
pub fn render_changes(changes: &[Change], theme: &Theme) -> impl IntoElement {
    let show = |value: &Option<String>| value.clone().unwrap_or_else(|| "(tomt)".to_owned());
    let summary: SharedString = if changes.is_empty() { "Inga ändringar.".into() } else { format!("{} ändringar", changes.len()).into() };
    v_flex()
        .id("changes")
        .test_support()
        .aria_label(summary.clone())
        .gap_1()
        .text_sm()
        .when(changes.is_empty(), |list| list.child(div().text_color(theme.muted_foreground).child(summary)))
        .children(changes.iter().map(|change| {
            h_flex().gap_2().child(div().font_semibold().child(change.key.clone())).child(show(&change.before)).child("→").child(show(&change.after))
        }))
}

/// A page's heading and one line saying what it is for.
pub fn page_header(title: &str, purpose: &str, cx: &App) -> impl IntoElement {
    v_flex()
        .gap_1()
        .child(div().text_xl().font_semibold().child(title.to_owned()))
        .child(div().text_sm().text_color(cx.theme().muted_foreground).child(purpose.to_owned()))
}

/// A section title inside a page.
pub fn section(title: &str) -> impl IntoElement {
    div().pt_2().font_semibold().child(title.to_owned())
}

/// Text for something being read right now, with a spinner beside it (static under reduced motion).
pub fn loading_line(text: &'static str, cx: &App) -> impl IntoElement {
    h_flex().gap_2().text_sm().text_color(cx.theme().muted_foreground).child(Spinner::new().small()).child(text)
}
