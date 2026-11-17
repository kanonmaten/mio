//! The app's UI integration tests, one module per page, in one test binary: each binary links all
//! of GPUI, which made five of them too slow for the gate's ten minutes on the laptop.

mod ai;
mod network;
mod transcription;
mod ui;
mod updates;
mod verify_logs;
