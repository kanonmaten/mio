//! Running a root-helper command or reading the gateway's model list without freezing the
//! window. Both go through [`Backend`], which tests replace with fakes.

use std::sync::Arc;

use gpui_kit::{App, Global, Task};
use mio_control_core::command::Command;
use mio_control_core::helper_client::{HelperError, run_helper};

pub type HelperFn = Arc<dyn Fn(&Command, Option<&[u8]>) -> Result<Vec<u8>, HelperError> + Send + Sync>;
pub type CatalogFn = Arc<dyn Fn() -> Result<Vec<u8>, String> + Send + Sync>;

/// Where the panel's privileged and gateway calls go.
#[derive(Clone)]
pub struct Backend {
    pub helper: HelperFn,
    /// `mio-gateway granskade-modeller`: runs as the user, the binary is world-readable.
    pub catalog: CatalogFn,
    /// OpenRouter's public model list, for the models nobody has reviewed yet. No key and no
    /// user data go with the request; a failure only leaves that group of the list empty.
    pub openrouter_models: CatalogFn,
}

impl Global for Backend {}

/// Models that support structured output, the only kind the gateway could ever use.
const OPENROUTER_MODELS: &str = "https://openrouter.ai/api/v1/models?supported_parameters=structured_outputs";

/// Where `server/install.sh` puts the gateway.
pub const GATEWAY: &str = "/opt/mio-gateway/mio-gateway";

impl Backend {
    pub fn system() -> Self {
        Self {
            helper: Arc::new(|command: &Command, stdin: Option<&[u8]>| run_helper(command, stdin)),
            catalog: Arc::new(|| {
                let output = std::process::Command::new(GATEWAY)
                    .arg("granskade-modeller")
                    .stdin(std::process::Stdio::null())
                    .output()
                    .map_err(|_| "AI-gatewayen är inte installerad. Kör server/install.sh först.".to_owned())?;
                if output.status.success() {
                    Ok(output.stdout)
                } else {
                    Err("Gatewayen på datorn är för gammal för panelen. Kör server/install.sh.".to_owned())
                }
            }),
            openrouter_models: Arc::new(|| {
                // curl is installed with the gateway (server/install.sh). HTTPS only, ten seconds.
                let output = std::process::Command::new("curl")
                    .args(["--silent", "--fail", "--proto", "=https", "--max-time", "10", OPENROUTER_MODELS])
                    .stdin(std::process::Stdio::null())
                    .output()
                    .map_err(|_| "curl saknas.".to_owned())?;
                if output.status.success() { Ok(output.stdout) } else { Err("OpenRouters modellista gick inte att hämta.".to_owned()) }
            }),
        }
    }
}

fn backend(cx: &App) -> Backend {
    cx.try_global::<Backend>().cloned().unwrap_or_else(Backend::system)
}

pub fn run(command: Command, stdin: Option<Vec<u8>>, cx: &App) -> Task<Result<Vec<u8>, HelperError>> {
    let helper = backend(cx).helper;
    cx.background_executor().spawn(async move { helper(&command, stdin.as_deref()) })
}

pub fn catalog(cx: &App) -> Task<Result<Vec<u8>, String>> {
    let catalog = backend(cx).catalog;
    cx.background_executor().spawn(async move { catalog() })
}

pub fn openrouter_models(cx: &App) -> Task<Result<Vec<u8>, String>> {
    let fetch = backend(cx).openrouter_models;
    cx.background_executor().spawn(async move { fetch() })
}
