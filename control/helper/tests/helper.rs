//! The helper against a temporary root with fake programs: no real `/etc`, systemd or Tailscale.

use std::cell::RefCell;
use std::path::Path;

use mio_control_core::atomic::backup_path;
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::http::{HttpError, Response};
use mio_control_core::settings::SettingsFile;
use mio_control_helper::{GATEWAY, Output, Runner, SYSTEMCTL, System, TAILSCALE, UPDATE_MODEL, execute};
use serde_json::{Value, json};

const TOKEN: &str = "fixture_gateway_token_01234567890123456789";
const KEY: &str = "gsk_fixture0123456789abcdefghij";
const GATEWAY_ENV: &str = "# Mio gateway. Dela aldrig denna fil.\nGROQ_API_KEY=gsk_fixture0123456789abcdefghij\nMIO_GATEWAY_TOKEN=fixture_gateway_token_01234567890123456789\nMIO_AI_PROVIDER=groq\nMIO_AI_MODEL=qwen/qwen3.8-27b\n# egen kommentar\nMIO_REQUESTS_PER_MINUTE=10\nPORT=8787\n";
const TRANSCRIPTION_CONF: &str = "MIO_TRANSCRIPTION_TOKEN=fixture_transcription_token_0123456789012\nMIO_MODEL_ID=KlangAI/pianissimo-sv\nMIO_MODEL_REVISION=0123456789abcdef0123456789abcdef01234567\n";

/// One program run: the program, its arguments and what it got on stdin.
type Call = (String, Vec<String>, Option<Vec<u8>>);

#[derive(Default)]
struct FakePrograms {
    calls: RefCell<Vec<Call>>,
    /// What `mio-gateway kontrollera-konfiguration` answers: (success, stdout, stderr).
    gateway_check: RefCell<Option<(bool, &'static str, &'static str)>>,
    serve_status: &'static str,
}

impl Runner for FakePrograms {
    fn run(&self, program: &str, arguments: &[&str], stdin: Option<&[u8]>) -> std::io::Result<Output> {
        self.calls.borrow_mut().push((program.to_owned(), arguments.iter().map(|word| (*word).to_owned()).collect(), stdin.map(<[u8]>::to_vec)));
        let ok = |stdout: &str| Ok(Output { success: true, stdout: stdout.as_bytes().to_vec(), stderr: Vec::new() });
        match (program, arguments) {
            (GATEWAY, ["kontrollera-konfiguration"]) => {
                let (success, stdout, stderr) = self.gateway_check.borrow().unwrap_or((true, "{\"valid\":true}", ""));
                Ok(Output { success, stdout: stdout.as_bytes().to_vec(), stderr: stderr.as_bytes().to_vec() })
            }
            (GATEWAY, ["tailscale-host"]) => ok("dator.tail1234.ts.net"),
            (GATEWAY, ["prova", _, "fails"]) => Ok(Output { success: false, stdout: b"{\"passed\":false}".to_vec(), stderr: b"FEL: Provet godk\xc3\xa4ndes inte.".to_vec() }),
            (GATEWAY, ["prova", provider, model]) => ok(&format!("{{\"provider\":\"{provider}\",\"model\":\"{model}\",\"passed\":true}}")),
            (GATEWAY, ["granskade-modeller"]) => ok("{\"models\":[{\"provider\":\"groq\",\"model\":\"qwen/qwen3.8-27b\"}],\"candidates\":[{\"provider\":\"mistral\",\"model\":\"mistral-small-2603\"}]}"),
            (GATEWAY, ["pairing-payload", host]) => ok(&format!("{{\"mio\":1,\"host\":\"{host}\"}}")),
            (TAILSCALE, ["status", "--json"]) => ok("{\"Self\":{\"DNSName\":\"dator.tail1234.ts.net.\"}}"),
            (TAILSCALE, ["serve", "status"]) => ok(self.serve_status),
            _ => ok(""),
        }
    }
}

struct Fixture {
    root: tempfile::TempDir,
    programs: FakePrograms,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("etc/mio-gateway")).unwrap();
        std::fs::write(root.path().join(SettingsFile::Gateway.path()), GATEWAY_ENV).unwrap();
        std::fs::write(root.path().join(SettingsFile::Transcription.path()), TRANSCRIPTION_CONF).unwrap();
        std::fs::write(root.path().join("etc/mio-transcription-vocabulary.txt"), "# Egna ord\n").unwrap();
        Self { root, programs: FakePrograms::default() }
    }

    fn run(&self, command: Command, stdin: &[u8]) -> Result<Vec<u8>, String> {
        let http = |port: u16, path: &str, bearer: Option<&str>, account: &str| -> Result<Response, HttpError> {
            match (port, path) {
                (8787, "/v2/status") => {
                    assert_eq!(account, "mio-gateway");
                    assert_eq!(bearer, Some(TOKEN));
                    Ok(Response { status: 200, body: b"{\"configurationRevision\":\"abc\"}".to_vec() })
                }
                (8765, "/health") => {
                    assert_eq!(account, "mio-transcription");
                    assert_eq!(bearer, Some("fixture_transcription_token_0123456789012"));
                    Ok(Response { status: 503, body: b"{\"status\":\"loading\"}".to_vec() })
                }
                _ => Err(HttpError::Refused),
            }
        };
        let system = System { root: self.root.path().to_owned(), runner: &self.programs, http: &http };
        execute(&system, &command, stdin)
    }

    fn file(&self, relative: &str) -> String {
        std::fs::read_to_string(self.root.path().join(relative)).unwrap()
    }

    fn calls(&self) -> Vec<(String, Vec<String>)> {
        self.programs.calls.borrow().iter().map(|(program, arguments, _)| (program.clone(), arguments.clone())).collect()
    }
}

fn json(bytes: Vec<u8>) -> Value {
    serde_json::from_slice(&bytes).unwrap()
}

#[test]
fn reading_settings_never_returns_a_secret() {
    let fixture = Fixture::new();
    let answer = fixture.run(Command::ReadSettings(SettingsFile::Gateway), b"").unwrap();
    let text = String::from_utf8(answer.clone()).unwrap();
    assert!(!text.contains(KEY) && !text.contains(TOKEN), "{text}");
    let answer = json(answer);
    assert_eq!(answer["values"]["MIO_AI_MODEL"], json!("qwen/qwen3.8-27b"));
    assert_eq!(answer["secrets"], json!({ "GROQ_API_KEY": true, "MIO_GATEWAY_TOKEN": true }));
    std::fs::remove_file(fixture.root.path().join(SettingsFile::Transcription.path())).unwrap();
    assert_eq!(json(fixture.run(Command::ReadSettings(SettingsFile::Transcription), b"").unwrap()), json!({ "exists": false }));
}

#[test]
fn a_settings_change_keeps_comments_is_checked_by_the_gateway_and_leaves_a_backup() {
    let fixture = Fixture::new();
    let change = br#"{"set":{"MIO_REQUESTS_PER_MINUTE":"20","MIO_TOKENS_PER_DAY":"150000"}}"#;
    let answer = json(fixture.run(Command::WriteSettings(SettingsFile::Gateway), change).unwrap());
    assert_eq!(answer["changed"], json!(["MIO_REQUESTS_PER_MINUTE", "MIO_TOKENS_PER_DAY"]));
    let written = fixture.file(SettingsFile::Gateway.path());
    assert_eq!(written, GATEWAY_ENV.replace("MIO_REQUESTS_PER_MINUTE=10", "MIO_REQUESTS_PER_MINUTE=20") + "MIO_TOKENS_PER_DAY=150000\n");
    assert_eq!(std::fs::read_to_string(backup_path(&fixture.root.path().join(SettingsFile::Gateway.path()))).unwrap(), GATEWAY_ENV);
    // The gateway saw exactly the bytes that were then written.
    let calls = fixture.programs.calls.borrow();
    let (program, arguments, stdin) = &calls[0];
    assert_eq!((program.as_str(), arguments.as_slice()), (GATEWAY, &["kontrollera-konfiguration".to_owned()][..]));
    assert_eq!(stdin.as_deref(), Some(written.as_bytes()));
}

#[test]
fn nothing_is_written_when_the_gateway_refuses() {
    let fixture = Fixture::new();
    *fixture.programs.gateway_check.borrow_mut() = Some((false, "", "FEL: Servergränserna får inte höja Mios minutkvot eller tidsgränser.\n"));
    let error = fixture.run(Command::WriteSettings(SettingsFile::Gateway), br#"{"set":{"MIO_REQUESTS_PER_MINUTE":"61"}}"#).unwrap_err();
    assert!(error.contains("minutkvot") && error.contains("Inget sparades"), "{error}");
    // An unreviewed model: the gateway would start, but the panel's lock refuses to save it.
    *fixture.programs.gateway_check.borrow_mut() = Some((false, "{\"valid\":false}", "FEL: En uppgift saknar en granskad modell"));
    let error = fixture.run(Command::WriteSettings(SettingsFile::Gateway), br#"{"set":{"MIO_AI_MODEL":"llama-3.3-70b"}}"#).unwrap_err();
    assert!(error.contains("granskad modell"), "{error}");
    // A gateway from before the check existed.
    *fixture.programs.gateway_check.borrow_mut() = Some((false, "", "FEL: Okänt kommando.\n"));
    let error = fixture.run(Command::WriteSettings(SettingsFile::Gateway), br#"{"set":{"MIO_REQUESTS_PER_MINUTE":"5"}}"#).unwrap_err();
    assert!(error.contains("server/install.sh"), "{error}");
    assert_eq!(fixture.file(SettingsFile::Gateway.path()), GATEWAY_ENV);
    assert!(!backup_path(&fixture.root.path().join(SettingsFile::Gateway.path())).exists());
}

#[test]
fn secrets_tokens_and_unknown_keys_cannot_be_written_as_settings() {
    let fixture = Fixture::new();
    for change in [
        &br#"{"set":{"GROQ_API_KEY":"gsk_stolen"}}"#[..],
        br#"{"set":{"MIO_GATEWAY_TOKEN":"x"}}"#,
        br#"{"set":{"PATH":"/tmp"}}"#,
        br#"{"set":{"PORT":"22"}}"#,
        br#"{"remove":["MIO_GATEWAY_TOKEN"]}"#,
        br#"{"set":{"MIO_AI_MODEL":"a\nGROQ_API_KEY=x"}}"#,
        br#"{"set":{"MIO_AI_MODEL":7}}"#,
        br#"{"extra":{}}"#,
        b"not json",
    ] {
        assert!(fixture.run(Command::WriteSettings(SettingsFile::Gateway), change).is_err(), "{}", String::from_utf8_lossy(change));
    }
    assert_eq!(fixture.file(SettingsFile::Gateway.path()), GATEWAY_ENV);
    assert!(fixture.calls().is_empty());
}

#[test]
fn transcription_settings_follow_pianissimos_limits() {
    let fixture = Fixture::new();
    let error = fixture.run(Command::WriteSettings(SettingsFile::Transcription), br#"{"set":{"MIO_VOCABULARY_BOOST":"2.5"}}"#).unwrap_err();
    assert!(error.contains("mellan 0 och 2"), "{error}");
    fixture.run(Command::WriteSettings(SettingsFile::Transcription), br#"{"set":{"MIO_PRECISION":"fp32","MIO_VOCABULARY_BOOST":"1.2"}}"#).unwrap();
    assert_eq!(fixture.file(SettingsFile::Transcription.path()), format!("{TRANSCRIPTION_CONF}MIO_PRECISION=fp32\nMIO_VOCABULARY_BOOST=1.2\n"));
    // Pianissimo is not checked by the gateway.
    assert!(fixture.calls().is_empty());
}

#[test]
fn a_new_provider_key_replaces_only_its_line_and_is_never_printed() {
    let fixture = Fixture::new();
    let answer = fixture.run(Command::WriteSecret("GROQ_API_KEY"), b"gsk_new0123456789abcdefghij\n").unwrap();
    assert!(!String::from_utf8(answer).unwrap().contains("gsk_new"));
    assert_eq!(fixture.file(SettingsFile::Gateway.path()), GATEWAY_ENV.replace(KEY, "gsk_new0123456789abcdefghij"));
    assert!(fixture.run(Command::WriteSecret("GROQ_API_KEY"), b"two words\n").is_err());
    assert!(fixture.run(Command::WriteSecret("GROQ_API_KEY"), format!("{TOKEN}\n").as_bytes()).is_err());
}

#[test]
fn a_rotated_token_has_the_services_shape() {
    let fixture = Fixture::new();
    fixture.run(Command::RotateToken(SettingsFile::Transcription), b"").unwrap();
    let written = fixture.file(SettingsFile::Transcription.path());
    let token = written.lines().find_map(|line| line.strip_prefix("MIO_TRANSCRIPTION_TOKEN=")).unwrap();
    assert!(mio_control_core::token::is_service_token(token) && token != "fixture_transcription_token_0123456789012");
    assert!(written.ends_with("MIO_MODEL_REVISION=0123456789abcdef0123456789abcdef01234567\n"));
}

#[test]
fn the_vocabulary_is_read_and_replaced_within_pianissimos_limits() {
    let fixture = Fixture::new();
    assert_eq!(fixture.run(Command::ReadVocabulary, b"").unwrap(), b"# Egna ord\n");
    fixture.run(Command::WriteVocabulary, "# Egna ord\nÅsa Lindqvist\n".as_bytes()).unwrap();
    assert_eq!(fixture.file("etc/mio-transcription-vocabulary.txt"), "# Egna ord\nÅsa Lindqvist\n");
    assert!(fixture.run(Command::WriteVocabulary, b"\xff").is_err());
    std::fs::remove_file(fixture.root.path().join("etc/mio-transcription-vocabulary.txt")).unwrap();
    assert!(fixture.run(Command::WriteVocabulary, b"ord\n").unwrap_err().contains("inte installerat"));
}

#[test]
fn services_and_updates_run_only_the_fixed_programs() {
    let fixture = Fixture::new();
    fixture.run(Command::Unit(UnitAction::Restart, Unit::Transcription), b"").unwrap();
    fixture.run(Command::UpdateTimer(false), b"").unwrap();
    fixture.run(Command::UpdateModel, b"").unwrap();
    let words = |words: &[&str]| words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(fixture.calls(), [
        (SYSTEMCTL.to_owned(), words(&["restart", "mio-transcription.service"])),
        (SYSTEMCTL.to_owned(), words(&["disable", "--now", "mio-pianissimo-update.timer"])),
        (UPDATE_MODEL.to_owned(), Vec::new()),
    ]);
}

#[test]
fn serve_is_set_up_like_the_installers_and_never_takes_over_443() {
    let mut fixture = Fixture::new();
    fixture.run(Command::SetupServe, b"").unwrap();
    let serve: Vec<Vec<String>> = fixture.calls().into_iter().filter(|(_, arguments)| arguments.get(1).is_some_and(|word| word == "--bg")).map(|(_, arguments)| arguments).collect();
    assert_eq!(serve, [
        vec!["serve", "--bg", "http://127.0.0.1:8765"],
        vec!["serve", "--bg", "--https=8443", "http://127.0.0.1:8787"],
    ]);
    assert!(fixture.calls().iter().all(|(_, arguments)| !arguments.contains(&"funnel".to_owned())));
    fixture.programs = FakePrograms { serve_status: "https://dator.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:3000\n", ..FakePrograms::default() };
    assert!(fixture.run(Command::SetupServe, b"").unwrap_err().contains("port 443"));
}

#[test]
fn pairing_data_comes_from_both_files_through_the_gateway() {
    let fixture = Fixture::new();
    let payload = json(fixture.run(Command::PairingData, b"").unwrap());
    assert_eq!(payload["host"], json!("dator.tail1234.ts.net"));
    let calls = fixture.programs.calls.borrow();
    let stdin = calls.iter().find(|(_, arguments, _)| arguments[0] == "pairing-payload").and_then(|(_, _, stdin)| stdin.clone()).unwrap();
    let stdin = String::from_utf8(stdin).unwrap();
    assert!(stdin.contains("MIO_GATEWAY_TOKEN=") && stdin.contains("MIO_TRANSCRIPTION_TOKEN="));
}

#[test]
fn the_gateway_status_is_fetched_with_the_token_the_panel_never_sees() {
    let fixture = Fixture::new();
    let answer = fixture.run(Command::ReadGatewayStatus, b"").unwrap();
    assert!(!String::from_utf8(answer.clone()).unwrap().contains(TOKEN));
    assert_eq!(json(answer), json!({ "httpStatus": 200, "body": { "configurationRevision": "abc" } }));
}

#[test]
fn missing_installations_are_named() {
    let fixture = Fixture::new();
    std::fs::remove_file(fixture.root.path().join(SettingsFile::Gateway.path())).unwrap();
    let error = fixture.run(Command::WriteSettings(SettingsFile::Gateway), br#"{"set":{"MIO_REQUESTS_PER_MINUTE":"5"}}"#).unwrap_err();
    assert!(error.contains("server/install.sh"), "{error}");
    assert!(!Path::new(&fixture.root.path().join(SettingsFile::Gateway.path())).exists());
}

#[test]
fn pianissimos_health_is_fetched_with_its_token_and_returned_without_it() {
    let fixture = Fixture::new();
    let answer = fixture.run(Command::ReadPianissimoHealth, b"").unwrap();
    assert!(!String::from_utf8(answer.clone()).unwrap().contains("fixture_transcription_token"));
    assert_eq!(json(answer), json!({ "httpStatus": 503, "body": { "status": "loading" } }));
}

#[test]
fn a_passed_trial_approves_a_candidate_and_nothing_else() {
    let fixture = Fixture::new();
    let trial = |provider: &'static str, model: &str| Command::TrialModel { provider, model: model.to_owned() };
    // A reviewed pair passes without touching the file.
    fixture.run(trial("groq", "qwen/qwen3.8-27b"), b"").unwrap();
    assert_eq!(fixture.file(SettingsFile::Gateway.path()), GATEWAY_ENV);
    // A failed trial is reported and approves nothing.
    let answer = json(fixture.run(trial("mistral", "fails"), b"").unwrap());
    assert_eq!(answer["passed"], false);
    assert_eq!(fixture.file(SettingsFile::Gateway.path()), GATEWAY_ENV);
    // A passed candidate is added once, and the gateway saw the file before it was written.
    fixture.run(trial("mistral", "mistral-small-2603"), b"").unwrap();
    fixture.run(trial("mistral", "mistral-small-2603"), b"").unwrap();
    assert_eq!(fixture.file(SettingsFile::Gateway.path()), format!("{GATEWAY_ENV}MIO_APPROVED_CANDIDATES=mistral=mistral-small-2603\n"));
    // The panel can never write the approval list as a plain setting.
    assert!(fixture.run(Command::WriteSettings(SettingsFile::Gateway), br#"{"set":{"MIO_APPROVED_CANDIDATES":"nvidia=qwen/qwen3.8-27b"}}"#).is_err());
}
