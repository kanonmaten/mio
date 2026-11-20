//! The window's frame: own title bar, a sidebar with one entry per page, and the current page.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::label::Label;
use gpui_kit::component::sidebar::{Sidebar, SidebarCollapsible, SidebarGroup, SidebarMenu, SidebarMenuItem};
use gpui_kit::component::{ActiveTheme as _, IconName, Sizable as _, TitleBar, h_flex, v_flex};
use gpui_kit::{
    AnyView, App, AppContext as _, Context, Entity, FocusHandle, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, Styled as _, Window, px,
};

use crate::ai::AiPage;
use crate::network::NetworkPage;
use crate::updates::UpdatesPage;
use crate::verify::VerifyPage;
use crate::logs::LogsPage;
use crate::computer::ComputerPage;
use crate::setup::{OpenPairing, SetupPage};
use crate::transcription::TranscriptionPage;
use crate::words::WordsPage;
use crate::model::StatusModel;
use crate::overview::OverviewPage;
use crate::window::{CloseWindow, ToggleFullscreen};

/// The pages, in sidebar order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Page {
    Overview,
    Setup,
    Ai,
    Transcription,
    Words,
    Network,
    Updates,
    Verify,
    Logs,
    Computer,
}

impl Page {
    pub const ALL: [Page; 10] = [
        Page::Overview,
        Page::Setup,
        Page::Ai,
        Page::Transcription,
        Page::Words,
        Page::Network,
        Page::Updates,
        Page::Verify,
        Page::Logs,
        Page::Computer,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Page::Overview => "Översikt",
            Page::Setup => "Kom igång",
            Page::Ai => "AI",
            Page::Transcription => "Transkription",
            Page::Words => "Egna ord",
            Page::Network => "Tailscale och parning",
            Page::Updates => "Uppdateringar",
            Page::Verify => "Verifiering",
            Page::Logs => "Loggar",
            Page::Computer => "Datorn",
        }
    }

    pub fn icon(self) -> IconName {
        match self {
            Page::Overview => IconName::LayoutDashboard,
            Page::Setup => IconName::Play,
            Page::Ai => IconName::Bot,
            Page::Transcription => IconName::Mic,
            Page::Words => IconName::FileText,
            Page::Network => IconName::Network,
            Page::Updates => IconName::RefreshCw,
            Page::Verify => IconName::CircleCheck,
            Page::Logs => IconName::SquareTerminal,
            Page::Computer => IconName::HardDrive,
        }
    }
}

/// Below this width the sidebar shows icons only (plan: the small window collapses it).
const SIDEBAR_COLLAPSE_BELOW: f32 = 860.;

pub struct Shell {
    focus: FocusHandle,
    page: Page,
    overview: Entity<OverviewPage>,
    ai: Entity<AiPage>,
    transcription: Entity<TranscriptionPage>,
    words: Entity<WordsPage>,
    network: Entity<NetworkPage>,
    updates: Entity<UpdatesPage>,
    verify: Entity<VerifyPage>,
    logs: Entity<LogsPage>,
    setup: Entity<SetupPage>,
    computer: Entity<ComputerPage>,
    _pairing: gpui_kit::Subscription,
}

impl Shell {
    pub fn new(status: Entity<StatusModel>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        focus.focus(window, cx);
        let overview = cx.new(|cx| OverviewPage::new(status.clone(), cx));
        let ai = cx.new(|cx| AiPage::new(status.clone(), window, cx));
        let transcription = cx.new(|cx| TranscriptionPage::new(status.clone(), cx));
        let words = cx.new(|cx| WordsPage::new(status.clone(), cx));
        let status_for_setup = status.clone();
        let network = cx.new(|cx| NetworkPage::new(status, window, cx));
        let updates = cx.new(|_| UpdatesPage::new());
        let verify = cx.new(VerifyPage::new);
        let logs = cx.new(|_| LogsPage::new());
        let setup = cx.new(|cx| SetupPage::new(status_for_setup, cx));
        let computer = cx.new(|_| ComputerPage);
        let pairing = cx.subscribe_in(&setup, window, |shell: &mut Self, _, _: &OpenPairing, window, cx| {
            shell.show(Page::Network, cx);
            shell.network.update(cx, |network, cx| network.show_pairing(window, cx));
        });
        Self { focus, page: Page::Overview, overview, ai, transcription, words, network, updates, verify, logs, setup, computer, _pairing: pairing }
    }

    pub fn page(&self) -> Page {
        self.page
    }

    pub fn show(&mut self, page: Page, cx: &mut Context<Self>) {
        if page == Page::Updates {
            // git fetch and checkupdates touch the network, so only when the page is opened.
            self.updates.update(cx, |updates, cx| updates.check_once(cx));
        }
        if page == Page::Logs {
            self.logs.update(cx, |logs, cx| logs.load_once(cx));
        }
        if self.page != page {
            self.page = page;
            cx.notify();
        }
    }

    fn page_view(&self) -> AnyView {
        match self.page {
            Page::Overview => self.overview.clone().into(),
            Page::Ai => self.ai.clone().into(),
            Page::Transcription => self.transcription.clone().into(),
            Page::Words => self.words.clone().into(),
            Page::Network => self.network.clone().into(),
            Page::Updates => self.updates.clone().into(),
            Page::Verify => self.verify.clone().into(),
            Page::Logs => self.logs.clone().into(),
            Page::Setup => self.setup.clone().into(),
            Page::Computer => self.computer.clone().into(),
        }
    }

    fn toggle_fullscreen(&mut self, _: &ToggleFullscreen, window: &mut Window, _: &mut Context<Self>) {
        window.toggle_fullscreen();
    }

    fn close_window(&mut self, _: &CloseWindow, window: &mut Window, _: &mut Context<Self>) {
        // Only the window goes; the tray icon keeps running.
        window.remove_window();
    }

    fn render_title_bar(&self, window: &Window) -> impl IntoElement {
        let fullscreen = window.is_fullscreen();
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
        )
    }

    fn render_sidebar(&self, collapsed: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let items = Page::ALL.map(|page| {
            SidebarMenuItem::new(page.title())
                .icon(page.icon())
                .active(self.page == page)
                .on_click(cx.listener(move |this, _, _, cx| this.show(page, cx)))
        });
        Sidebar::new("pages")
            .collapsible(SidebarCollapsible::Icon)
            .collapsed(collapsed)
            .w(px(200.))
            .child(SidebarGroup::new("Mio").child(SidebarMenu::new().children(items)))
    }
}

impl Render for Shell {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let collapsed = window.viewport_size().width < px(SIDEBAR_COLLAPSE_BELOW);
        v_flex()
            .key_context("MioKontroll")
            .track_focus(&self.focus)
            .on_action(cx.listener(Self::toggle_fullscreen))
            .on_action(cx.listener(Self::close_window))
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(self.render_title_bar(window))
            .child(
                h_flex()
                    .items_stretch()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_sidebar(collapsed, cx))
                    .child(gpui_kit::div().flex_1().min_w_0().min_h_0().child(self.page_view())),
            )
    }
}

/// Runs `f` on the open window's shell and brings the window forward.
fn with_shell(cx: &mut App, f: impl Fn(&mut Shell, &mut Window, &mut Context<Shell>)) {
    for window in cx.windows() {
        let _ = window.update(cx, |root, window, cx| {
            if let Ok(root) = root.downcast::<gpui_kit::base::Root>()
                && let Ok(shell) = root.read(cx).view().clone().downcast::<Shell>()
            {
                shell.update(cx, |shell, cx| f(shell, window, cx));
                window.activate_window();
            }
        });
    }
}

/// Opens `page` in the window, if the window is open.
pub fn show_page(page: Page, cx: &mut App) {
    with_shell(cx, |shell, _, cx| shell.show(page, cx));
}

/// Opens Tailscale och parning and asks for the pairing code (the tray's "Visa parningskod").
pub fn show_pairing(cx: &mut App) {
    with_shell(cx, |shell, window, cx| {
        shell.show(Page::Network, cx);
        shell.network.update(cx, |network, cx| network.show_pairing(window, cx));
    });
}
