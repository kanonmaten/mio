//! The window's content. Phase 0: title bar and one action; the pages come in phase 2.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::label::Label;
use gpui_kit::component::{ActiveTheme as _, IconName, Sizable as _, TitleBar, h_flex, v_flex};
use gpui_kit::{
    Context, FocusHandle, InteractiveElement as _, IntoElement, ParentElement as _, Render, Styled as _, Window,
};

use crate::window::{CloseWindow, ToggleFullscreen};

pub struct Shell {
    focus: FocusHandle,
}

impl Shell {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        focus.focus(window, cx);
        Self { focus }
    }

    fn toggle_fullscreen(&mut self, _: &ToggleFullscreen, window: &mut Window, _: &mut Context<Self>) {
        window.toggle_fullscreen();
    }

    fn close_window(&mut self, _: &CloseWindow, window: &mut Window, _: &mut Context<Self>) {
        // Only the window goes; the tray icon keeps running.
        window.remove_window();
    }
}

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let fullscreen = window.is_fullscreen();
        v_flex()
            .key_context("MioKontroll")
            .track_focus(&self.focus)
            .on_action(cx.listener(Self::toggle_fullscreen))
            .on_action(cx.listener(Self::close_window))
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                TitleBar::new().child(
                    h_flex()
                        .w_full()
                        .pr_2()
                        .justify_between()
                        .child(Label::new("Mio Kontroll"))
                        .child(
                            Button::new("fullscreen")
                                .ghost()
                                .small()
                                .icon(if fullscreen { IconName::Minimize } else { IconName::Maximize })
                                .tooltip(if fullscreen { "Lämna helskärm (F11)" } else { "Helskärm (F11)" })
                                .on_click(|_, window, _| window.toggle_fullscreen()),
                        ),
                ),
            )
            .child(
                v_flex()
                    .flex_1()
                    .items_center()
                    .justify_center()
                    .gap_3()
                    .child(Label::new("Mio Kontroll startar här."))
                    .child(Button::new("close").label("Stäng fönstret").on_click(|_, window, _| window.remove_window())),
            )
    }
}
