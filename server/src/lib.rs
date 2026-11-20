//! Mio's private AI gateway: takes approved questions, everyday excerpts and lesson parts from
//! the app and sends them to one reviewed model. No audio arrives here and no text is stored.

pub mod adapters;
pub mod analysis;
pub mod config;
pub mod error;
pub mod generation;
pub mod js;
pub mod model_profiles;
pub mod prompts;
pub mod server;
pub mod state_store;
pub mod status;
pub mod task_profiles;
pub mod tasks;
pub mod time;
pub mod tools;
pub mod transport;
pub mod usage;
