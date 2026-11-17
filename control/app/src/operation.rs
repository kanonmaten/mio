//! Running a root-helper command without freezing the window: pkexec (and the password dialog)
//! waits on the background executor; the caller gets a task with the helper's answer.

use gpui_kit::{App, Task};
use mio_control_core::command::Command;
use mio_control_core::helper_client::{HelperError, run_helper};

pub fn run(command: Command, stdin: Option<Vec<u8>>, cx: &App) -> Task<Result<Vec<u8>, HelperError>> {
    cx.background_executor().spawn(async move { run_helper(&command, stdin.as_deref()) })
}
