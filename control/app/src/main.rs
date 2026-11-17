//! `mio-control [--visa]`: the tray app; `--visa` also opens the window.

fn main() {
    mio_control::run(std::env::args().any(|argument| argument == "--visa"));
}
