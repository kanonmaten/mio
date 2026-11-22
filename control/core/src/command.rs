//! The root helper's fixed command list, shared by the panel (which builds commands) and the
//! helper (which parses them). The first word is the polkit group (`status`, `read`, `write`,
//! `service`, `pair`); pkexec picks `app.mio.control.<group>` from it. `status` needs no password
//! because the panel polls it every few seconds; it returns no key, token or word. No command takes a path, a shell
//! word or a program name from the panel: every argument is one of the fixed words below.

use crate::settings::{PROVIDER_SECRET_KEYS, SettingsFile};

/// A systemd unit the helper may start, stop or restart.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Unit {
    Gateway,
    Transcription,
}

impl Unit {
    pub const ALL: [Unit; 2] = [Unit::Gateway, Unit::Transcription];

    pub fn name(self) -> &'static str {
        match self {
            Unit::Gateway => "mio-gateway.service",
            Unit::Transcription => "mio-transcription.service",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|unit| unit.name() == name)
    }
}

/// The nightly Pianissimo update timer.
pub const UPDATE_TIMER: &str = "mio-pianissimo-update.timer";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum UnitAction {
    Start,
    Stop,
    Restart,
}

impl UnitAction {
    const ALL: [UnitAction; 3] = [UnitAction::Start, UnitAction::Stop, UnitAction::Restart];

    pub fn verb(self) -> &'static str {
        match self {
            UnitAction::Start => "start",
            UnitAction::Stop => "stop",
            UnitAction::Restart => "restart",
        }
    }
}

/// The gateway's providers (`PROVIDERS` in `server/src/model_profiles.rs`).
pub const PROVIDER_IDS: [&str; 7] = ["groq", "anthropic", "mistral", "nvidia", "openai", "openrouter", "gemini"];

/// A model name the gateway could accept: what `provider_profile` checks before its catalog.
pub fn is_model_name(model: &str) -> bool {
    let mut characters = model.chars();
    model.len() <= 128
        && characters.next().is_some_and(|first| first.is_ascii_alphanumeric())
        && characters.all(|character| character.is_ascii_alphanumeric() || "._:/-".contains(character))
        && !model.contains("://")
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Command {
    /// A settings file as JSON, secrets replaced by whether they are set.
    ReadSettings(SettingsFile),
    /// The gateway's `/v2/status`, fetched with the token the panel never sees.
    ReadGatewayStatus,
    /// Pianissimo's `/health`, which also needs its token.
    ReadPianissimoHealth,
    /// The user's own words. Only root and the service may read the file.
    ReadVocabulary,
    /// Changes plain settings; JSON on stdin. The gateway checks its file before it is written.
    WriteSettings(SettingsFile),
    /// A provider key on stdin, into `gateway.env`.
    WriteSecret(&'static str),
    /// A new random token; the phone must be paired again.
    RotateToken(SettingsFile),
    /// The vocabulary on stdin.
    WriteVocabulary,
    Unit(UnitAction, Unit),
    /// Turns the nightly model update on or off.
    UpdateTimer(bool),
    /// Runs Pianissimo's `update-model.sh` now.
    UpdateModel,
    /// One synthetic call per task against a provider and model (`mio-gateway prova`); a passed
    /// candidate becomes selectable. Real provider traffic: only when the user presses the button.
    TrialModel { provider: &'static str, model: String },
    /// `tailscale serve` for 443 → 8765 and 8443 → 8787, as the installers do.
    SetupServe,
    /// The pairing payload with both tokens.
    PairingData,
}

impl Command {
    /// The polkit group, which is also the first argument.
    pub fn group(&self) -> &'static str {
        match self {
            Command::ReadGatewayStatus | Command::ReadPianissimoHealth => "status",
            Command::ReadSettings(_) | Command::ReadVocabulary => "read",
            Command::WriteSettings(_) | Command::WriteSecret(_) | Command::RotateToken(_) | Command::WriteVocabulary => "write",
            Command::Unit(..) | Command::UpdateTimer(_) | Command::UpdateModel | Command::SetupServe | Command::TrialModel { .. } => "service",
            Command::PairingData => "pair",
        }
    }

    /// Whether the command reads its payload (a secret, settings or words) from stdin.
    pub fn takes_stdin(&self) -> bool {
        matches!(self, Command::WriteSettings(_) | Command::WriteSecret(_) | Command::WriteVocabulary)
    }

    pub fn to_args(&self) -> Vec<String> {
        let words: Vec<&str> = match self {
            Command::ReadSettings(file) => vec!["installningar", file.id()],
            Command::ReadGatewayStatus => vec!["gateway"],
            Command::ReadPianissimoHealth => vec!["pianissimo"],
            Command::ReadVocabulary => vec!["ordlista"],
            Command::WriteSettings(file) => vec!["installningar", file.id()],
            Command::WriteSecret(key) => vec!["nyckel", key],
            Command::RotateToken(file) => vec!["token", file.id()],
            Command::WriteVocabulary => vec!["ordlista"],
            Command::Unit(action, unit) => vec![action.verb(), unit.name()],
            Command::UpdateTimer(on) => vec!["nattuppdatering", if *on { "pa" } else { "av" }],
            Command::UpdateModel => vec!["uppdatera-modell"],
            Command::SetupServe => vec!["serve"],
            Command::TrialModel { provider, model } => vec!["prova", provider, model],
            Command::PairingData => vec!["parningsdata"],
        };
        std::iter::once(self.group()).chain(words).map(str::to_owned).collect()
    }

    /// Parses the helper's arguments. Anything not on the list is refused.
    pub fn parse(arguments: &[String]) -> Result<Command, &'static str> {
        let words: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let file = |id: &str| SettingsFile::from_id(id).ok_or(REFUSED);
        let command = match words.as_slice() {
            ["read", "installningar", id] => Command::ReadSettings(file(id)?),
            ["status", "gateway"] => Command::ReadGatewayStatus,
            ["status", "pianissimo"] => Command::ReadPianissimoHealth,
            ["read", "ordlista"] => Command::ReadVocabulary,
            ["write", "installningar", id] => Command::WriteSettings(file(id)?),
            ["write", "nyckel", key] => {
                Command::WriteSecret(PROVIDER_SECRET_KEYS.iter().find(|known| *known == key).copied().ok_or(REFUSED)?)
            }
            ["write", "token", id] => Command::RotateToken(file(id)?),
            ["write", "ordlista"] => Command::WriteVocabulary,
            ["service", verb, unit] if UnitAction::ALL.iter().any(|action| action.verb() == *verb) => {
                let action = UnitAction::ALL.into_iter().find(|action| action.verb() == *verb).ok_or(REFUSED)?;
                Command::Unit(action, Unit::from_name(unit).ok_or(REFUSED)?)
            }
            ["service", "nattuppdatering", "pa"] => Command::UpdateTimer(true),
            ["service", "nattuppdatering", "av"] => Command::UpdateTimer(false),
            ["service", "uppdatera-modell"] => Command::UpdateModel,
            ["service", "serve"] => Command::SetupServe,
            ["service", "prova", provider, model] if is_model_name(model) => Command::TrialModel {
                provider: PROVIDER_IDS.iter().find(|known| *known == provider).copied().ok_or(REFUSED)?,
                model: (*model).to_owned(),
            },
            ["pair", "parningsdata"] => Command::PairingData,
            _ => return Err(REFUSED),
        };
        Ok(command)
    }
}

pub const REFUSED: &str = "Okänt eller otillåtet kommando.";

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    fn every_command() -> Vec<Command> {
        let mut commands = vec![
            Command::ReadGatewayStatus,
            Command::ReadPianissimoHealth,
            Command::ReadVocabulary,
            Command::WriteVocabulary,
            Command::UpdateTimer(true),
            Command::UpdateTimer(false),
            Command::UpdateModel,
            Command::SetupServe,
            Command::PairingData,
            Command::TrialModel { provider: "anthropic", model: "claude-haiku-5-5".into() },
        ];
        for file in SettingsFile::ALL {
            commands.extend([Command::ReadSettings(file), Command::WriteSettings(file), Command::RotateToken(file)]);
        }
        commands.extend(PROVIDER_SECRET_KEYS.iter().map(|key| Command::WriteSecret(key)));
        for unit in Unit::ALL {
            commands.extend(UnitAction::ALL.map(|action| Command::Unit(action, unit)));
        }
        commands
    }

    #[test]
    fn every_command_round_trips_and_starts_with_its_polkit_group() {
        for command in every_command() {
            let arguments = command.to_args();
            assert_eq!(arguments[0], command.group());
            assert_eq!(Command::parse(&arguments), Ok(command.clone()), "{arguments:?}");
        }
    }

    #[test]
    fn anything_else_is_refused() {
        for words in [
            &[][..],
            &["read"],
            &["read", "installningar", "/etc/shadow"],
            &["read", "installningar", "../gateway"],
            &["write", "nyckel", "PATH"],
            &["write", "nyckel", "MIO_GATEWAY_TOKEN"],
            &["service", "restart", "sshd.service"],
            &["service", "restart", "mio-gateway"],
            &["service", "enable", "mio-gateway.service"],
            &["service", "nattuppdatering", "ja"],
            &["pair", "parningsdata", "extra"],
            &["write", "installningar", "gateway", "extra"],
            &["root", "sh", "-c", "id"],
            // The group must match the command, or polkit would ask under the wrong rule.
            &["read", "ordlista", "x"],
            &["write", "gateway"],
            &["read", "gateway"],
            &["status", "ordlista"],
            &["status", "installningar", "gateway"],
            &["read", "parningsdata"],
            &["service", "token", "gateway"],
            &["service", "prova", "deepseek", "gpt"],
            &["service", "prova", "groq", "-rf"],
            &["service", "prova", "groq", "http://evil"],
            &["read", "prova", "groq", "qwen/qwen3.8-27b"],
        ] {
            assert_eq!(Command::parse(&args(words)), Err(REFUSED), "{words:?}");
        }
    }

    #[test]
    fn only_writes_read_stdin() {
        for command in every_command() {
            assert_eq!(command.takes_stdin(), command.group() == "write" && !matches!(command, Command::RotateToken(_)));
        }
    }
}
