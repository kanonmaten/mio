//! Prints what the overview would show, without a window:
//! `cargo run -p mio-control-core --example status_probe`

use mio_control_core::probe;
use mio_control_core::status::Overview;
use zbus::blocking::Connection;

fn main() {
    let overview = probe::overview(8787, &Overview::default());
    println!("{overview:#?}");
    println!("Systemfältet: {:?} — {}", overview.tray_status(), overview.summary());
    if let Ok(connection) = Connection::system() {
        println!("systemd-journald.service: {:?}", probe::unit_state(&connection, "systemd-journald.service"));
    }
}
