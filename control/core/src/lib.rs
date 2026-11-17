//! Mio Kontroll's core: everything that does not need a window, so it is tested on Linux and in CI.

pub mod atomic;
pub mod command;
pub mod env_file;
pub mod format;
pub mod helper_client;
pub mod http;
pub mod probe;
pub mod settings;
pub mod socket_owner;
pub mod status;
pub mod token;
pub mod tray_icon;
pub mod verification;
