//! Portable structural checks; this does not compile Swift or run XCTest.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use plist::Value as Plist;
use regex::Regex;
use serde_json::Value;

use crate::util::{has_trailing_whitespace, root, splitlines};

/// Passed and failed check descriptions, printed the same way as before the port.
#[derive(Default)]
pub struct Report {
    pub checks: Vec<String>,
    pub errors: Vec<String>,
}

impl Report {
    fn check(&mut self, condition: bool, description: impl Into<String>) {
        if condition { &mut self.checks } else { &mut self.errors }.push(description.into());
    }
}

fn pattern(text: &str) -> Regex {
    Regex::new(text).expect("valid pattern")
}

/// The text between an object's `= {` and its balanced closing brace, or "".
fn object_body<'a>(project: &'a str, identifier: &str) -> &'a str {
    let declaration = pattern(&format!(r"\b{identifier}(?: /\*[^*]+\*/)? = \{{"));
    let Some(found) = declaration.find(project) else { return "" };
    let start = found.end();
    let mut depth = 1;
    for (index, byte) in project.bytes().enumerate().skip(start) {
        depth += i32::from(byte == b'{') - i32::from(byte == b'}');
        if depth == 0 {
            return &project[start..index];
        }
    }
    ""
}

/// Resolve group-relative file paths, not just filenames in Sources phases.
fn resolved_group_files(project: &str, references: &HashMap<String, String>, group: &str, parent: &Path) -> Vec<PathBuf> {
    let body = object_body(project, group);
    let directory = match pattern(r"\bpath = ([^;]+);").captures(body) {
        Some(path) => parent.join(path[1].trim_matches('"')),
        None => parent.to_path_buf(),
    };
    let children = pattern(r"(?s)children = \((.*?)\);");
    let children = children.captures(body).map(|captures| captures[1].to_owned()).unwrap_or_default();
    let mut resolved = Vec::new();
    for child in pattern(r"[A-F0-9]{24}").find_iter(&children) {
        let child = child.as_str();
        if let Some(name) = references.get(child) {
            let name = name.trim_matches('"');
            if name.ends_with(".swift") {
                resolved.push(directory.join(name));
            }
        } else if object_body(project, child).contains("isa = PBXGroup;") {
            resolved.extend(resolved_group_files(project, references, child, &directory));
        }
    }
    resolved
}

fn run_commands(steps: Option<&Value>) -> Result<String, ()> {
    let steps = match steps {
        None => return Ok(String::new()),
        Some(Value::Array(steps)) => steps,
        Some(_) => return Err(()),
    };
    // A step without `run` still contributes an empty line, as '\n'.join did.
    let commands: Vec<&str> = steps
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|step| match step.get("run") {
            None => Some(""),
            Some(Value::String(run)) => Some(run.as_str()),
            Some(_) => None,
        })
        .collect();
    Ok(commands.join("\n"))
}

/// Return missing safety-critical fields for Mio's two required workflows.
pub fn workflow_contract_issues(name: &str, workflow: &Value) -> Vec<String> {
    let Some(jobs) = workflow.get("jobs").and_then(Value::as_object).filter(|_| workflow.is_object()) else {
        return vec!["YAML-roten måste innehålla en jobs-mappning".to_owned()];
    };
    let checks: Vec<(bool, &str)> = match name {
        "build-unsigned-ipa.yml" => {
            // Two parallel jobs on Xcode: the IPA does not wait for the simulator tests. A small
            // `plan` job chooses which tests run and whether a PR touches the app; the IPA job may
            // wait for it (about 15 s, MIO-28) but for nothing else.
            let mut commands = HashMap::new();
            for key in ["ipa", "test"] {
                let steps = jobs.get(key).and_then(Value::as_object).and_then(|job| job.get("steps"));
                match run_commands(steps) {
                    Ok(joined) => commands.insert(key, joined),
                    Err(()) => return vec![format!("jobbet {key}: steps måste vara en lista")],
                };
            }
            let (ipa, test) = (&commands["ipa"], &commands["test"]);
            let only_known_jobs = jobs.keys().all(|key| ["ipa", "test", "plan"].contains(&key.as_str()));
            let ipa_waits = jobs.get("ipa").and_then(Value::as_object).is_some_and(|job| {
                job.get("needs").is_some_and(|needs| match needs {
                    Value::String(job) => job != "plan",
                    Value::Array(jobs) => jobs.iter().any(|job| job.as_str() != Some("plan")),
                    _ => true,
                })
            });
            let on_xcode = only_known_jobs
                && !ipa_waits
                && ["ipa", "test"].iter().all(|key| {
                    jobs.get(*key)
                        .and_then(Value::as_object)
                        .is_some_and(|job| job.get("runs-on").and_then(Value::as_str) == Some("xcode-27"))
                });
            vec![
                (on_xcode, "IPA- och testjobb på xcode-27"),
                (
                    ipa.contains("-configuration Release") && ipa.contains("Mio-unsigned.ipa") && ipa.contains("Mio-buildinfo.txt"),
                    "Release, IPA-validering och byggproveniens",
                ),
                (ipa.contains("CURRENT_PROJECT_VERSION=\"$GITHUB_RUN_NUMBER\""), "byggnummer från körningens nummer"),
                (test.contains("test-without-building") && test.contains("MioUITests"), "XCTest och UI-tester"),
                (
                    test.contains("tools/Cargo.toml") && test.contains("concurrency --native"),
                    "native strict-concurrencydiagnostik",
                ),
            ]
        }
        "verify-linux.yml" => {
            let empty = serde_json::Map::new();
            let job = jobs.get("verify").and_then(Value::as_object).unwrap_or(&empty);
            let commands = match run_commands(job.get("steps")) {
                Ok(commands) => commands,
                Err(()) => return vec!["jobbets steps måste vara en lista".to_owned()],
            };
            let steps = job.get("steps").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
            let uploads = steps.iter().filter_map(Value::as_object).any(|step| {
                step.get("uses")
                    .and_then(Value::as_str)
                    .is_some_and(|action| action.starts_with("actions/upload-artifact@"))
            });
            vec![
                (
                    job.get("runs-on").and_then(Value::as_str) == Some("ubuntu-24.04")
                        && job.get("container").and_then(Value::as_str) == Some("swift:6.3.3-noble"),
                    "Ubuntu 24.04 och Swift 6.3.3 Noble",
                ),
                (
                    commands.contains("tools/Cargo.toml") && commands.contains("-- verify") && commands.contains("--logs-dir"),
                    "den gemensamma verifieraren med sparad loggplats",
                ),
                (uploads, "uppladdning av verifieringsbevis"),
            ]
        }
        _ => return Vec::new(),
    };
    checks
        .into_iter()
        .filter(|(present, _)| !present)
        .map(|(_, description)| description.to_owned())
        .collect()
}

/// A YAML document as JSON values; mapping keys become their scalar text.
fn yaml_to_json(yaml: &yaml_rust2::Yaml) -> Value {
    use yaml_rust2::Yaml;
    match yaml {
        Yaml::Real(text) => text.parse::<f64>().ok().and_then(serde_json::Number::from_f64).map_or(Value::Null, Value::Number),
        Yaml::Integer(number) => Value::from(*number),
        Yaml::String(text) => Value::from(text.as_str()),
        Yaml::Boolean(value) => Value::from(*value),
        Yaml::Array(items) => Value::Array(items.iter().map(yaml_to_json).collect()),
        Yaml::Hash(map) => Value::Object(
            map.iter()
                .map(|(key, value)| {
                    let key = match key {
                        Yaml::String(text) | Yaml::Real(text) => text.clone(),
                        Yaml::Integer(number) => number.to_string(),
                        Yaml::Boolean(value) => value.to_string(),
                        _ => "null".to_owned(),
                    };
                    (key, yaml_to_json(value))
                })
                .collect(),
        ),
        Yaml::Alias(_) | Yaml::Null | Yaml::BadValue => Value::Null,
    }
}

/// `yaml.safe_load`: one document; an empty file is null.
fn load_yaml(text: &str) -> Result<Value, String> {
    let documents = yaml_rust2::YamlLoader::load_from_str(text).map_err(|error| error.to_string())?;
    match documents.as_slice() {
        [] => Ok(Value::Null),
        [document] => Ok(yaml_to_json(document)),
        _ => Err("expected a single document in the stream".to_owned()),
    }
}

/// Python truthiness for a property-list value.
fn truthy(value: Option<&Plist>) -> bool {
    match value {
        None => false,
        Some(Plist::String(text)) => !text.is_empty(),
        Some(Plist::Boolean(value)) => *value,
        Some(Plist::Array(items)) => !items.is_empty(),
        Some(Plist::Dictionary(map)) => !map.is_empty(),
        Some(Plist::Data(bytes)) => !bytes.is_empty(),
        Some(Plist::Integer(number)) => number.as_signed().is_none_or(|number| number != 0),
        Some(Plist::Real(number)) => *number != 0.0,
        Some(_) => true,
    }
}

fn string_list(value: Option<&Plist>) -> Option<Vec<&str>> {
    value?.as_array()?.iter().map(Plist::as_string).collect()
}

/// Fatal problems stop the check, as an uncaught KeyError/OSError/ValueError did.
struct Fatal(String);

impl<E: std::fmt::Display> From<E> for Fatal {
    fn from(error: E) -> Self {
        Fatal(error.to_string())
    }
}

fn read_text(path: &Path) -> Result<String, Fatal> {
    std::fs::read_to_string(path).map_err(|error| Fatal(format!("{}: {error}", path.display())))
}

fn read_plist(path: &Path) -> Result<Plist, Fatal> {
    Plist::from_file(path).map_err(|error| Fatal(format!("{}: {error}", path.display())))
}

fn key_error(key: &str) -> Fatal {
    Fatal(format!("'{key}'"))
}

/// Files under `directory`, recursively, in sorted order. Directories named in `skip` are
/// not entered; symlinked directories are not followed.
fn walk(directory: &Path, skip: &[&str], files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(directory) else { return };
    let mut entries: Vec<PathBuf> = entries.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
        if skip.contains(&name) {
            continue;
        }
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_dir() => walk(&path, skip, files),
            Ok(_) => files.push(path),
            Err(_) => {}
        }
    }
}

fn files_with_suffix(directory: &Path, suffix: &str) -> Vec<PathBuf> {
    let mut files = Vec::new();
    walk(directory, &[], &mut files);
    files.retain(|path| path.to_string_lossy().ends_with(suffix));
    files
}

fn glob_one_level(directory: &Path, suffix: &str) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(directory)
        .map(|entries| entries.filter_map(|entry| entry.ok().map(|entry| entry.path())).collect())
        .unwrap_or_default();
    found.retain(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(suffix))
    });
    found.sort();
    found
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root).unwrap_or(path).display().to_string()
}

pub fn check_project(root: &Path) -> Result<Report, String> {
    let mut report = Report::default();
    match structure(root, &mut report) {
        Ok(()) => Ok(report),
        Err(Fatal(message)) => Err(message),
    }
}

fn structure(root: &Path, report: &mut Report) -> Result<(), Fatal> {
    let project = read_text(&root.join("Mio.xcodeproj/project.pbxproj"))?;
    let declarations: Vec<&str> = pattern(r"(?m)^\t\t([A-F0-9]{24})(?: /\*[^*]+\*/)? = \{")
        .captures_iter(&project)
        .map(|captures| captures.get(1).expect("group").as_str())
        .collect();
    let mut unique = declarations.clone();
    unique.sort_unstable();
    unique.dedup();
    report.check(declarations.len() == unique.len(), "Unika Xcode-objektidentiteter");
    let references: HashMap<String, String> =
        pattern(r"([A-F0-9]{24}) /\*[^*]+\*/ = \{isa = PBXFileReference;[^\n]*?path = ([^;]+);")
            .captures_iter(&project)
            .map(|captures| (captures[1].to_owned(), captures[2].to_owned()))
            .collect();
    for path in resolved_group_files(&project, &references, "710000000000000000000001", Path::new("")) {
        report.check(root.join(&path).is_file(), format!("Xcode-gruppens källsökväg finns: {}", path.display()));
    }
    let builds: HashMap<String, String> =
        pattern(r"([A-F0-9]{24}) /\*[^*]+\*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})")
            .captures_iter(&project)
            .map(|captures| (captures[1].to_owned(), captures[2].to_owned()))
            .collect();
    // The widget extension also compiles the Foundation/ActivityKit sources it shares with the app.
    let widget_shared = ["MioListeningActivityState.swift", "MioListeningAttributes.swift"];
    let in_sources = pattern(r"([A-F0-9]{24}) /\*[^*]+in Sources \*/");
    for (folder, phase, shared) in [
        ("Mio", "910000000000000000000001", &[][..]),
        ("MioTests", "910000000000000000000002", &[][..]),
        ("MioUITests", "920000000000000000000001", &[][..]),
        ("MioWidgets", "BAC600000000000000000401", &widget_shared[..]),
    ] {
        let body = object_body(&project, phase);
        let mut target_files: Vec<String> = in_sources
            .captures_iter(body)
            .map(|captures| {
                let file = builds.get(&captures[1]).map(String::as_str).unwrap_or_default();
                references.get(file).map(String::as_str).unwrap_or_default().trim_matches('"').to_owned()
            })
            .collect();
        let mut expected: Vec<String> = files_with_suffix(&root.join(folder), ".swift")
            .iter()
            .filter_map(|path| path.file_name().map(|name| name.to_string_lossy().into_owned()))
            .chain(shared.iter().map(|name| (*name).to_owned()))
            .collect();
        let count = expected.len();
        target_files.sort();
        expected.sort();
        report.check(
            target_files == expected,
            format!("{folder}: exakt alla {count} Swift-filer ingår en gång i rätt target"),
        );
    }
    for name in widget_shared {
        let matches = files_with_suffix(&root.join("Mio"), name)
            .iter()
            .filter(|path| path.file_name().is_some_and(|file| file == name))
            .count();
        report.check(matches == 1, format!("Delad widgetkälla finns i appen: {name}"));
    }
    let embed = object_body(&project, "BAC600000000000000000404");
    report.check(
        embed.contains("dstSubfolderSpec = 13;")
            && embed.contains("MioWidgets.appex in Embed Foundation Extensions")
            && object_body(&project, "A10000000000000000000001").contains("BAC600000000000000000404"),
        "Widgettillägget bäddas in i appens PlugIns",
    );
    report.check(
        project.matches("PRODUCT_BUNDLE_IDENTIFIER = app.mio.assistant.widgets;").count() == 2,
        "Widgetidentiteten app.mio.assistant.widgets i Debug och Release",
    );
    let mut versions: Vec<&str> = pattern(r"CURRENT_PROJECT_VERSION = ([^;]+);")
        .captures_iter(&project)
        .map(|captures| captures.get(1).expect("group").as_str())
        .collect();
    versions.sort_unstable();
    versions.dedup();
    report.check(versions.len() == 1, "Appen och widgettillägget har samma byggnummer");

    let widget_info = read_plist(&root.join("MioWidgets/Info.plist"))?;
    let extension_point = widget_info
        .as_dictionary()
        .and_then(|info| info.get("NSExtension"))
        .and_then(Plist::as_dictionary)
        .and_then(|extension| extension.get("NSExtensionPointIdentifier"))
        .and_then(Plist::as_string);
    report.check(extension_point == Some("com.apple.widgetkit-extension"), "Widgettilläggets extension point");
    for path in glob_one_level(&root.join("Mio"), ".plist") {
        let info = read_plist(&path)?;
        let empty = plist::Dictionary::new();
        let info = info.as_dictionary().unwrap_or(&empty);
        report.check(truthy(info.get("NSMicrophoneUsageDescription")), "Mikrofonens behörighetstext");
        report.check(truthy(info.get("NSAlarmKitUsageDescription")), "AlarmKits behörighetstext");
        report.check(truthy(info.get("NSCameraUsageDescription")), "Kamerans behörighetstext för QR-parning");
        report.check(truthy(info.get("NSRemindersFullAccessUsageDescription")), "Påminnelsers behörighetstext");
        report.check(
            !info.keys().any(|key| key.starts_with("NSCalendars")),
            "Ingen kalenderbehörighet; Kalenders egen redigerare används",
        );
        let schemes: Option<Vec<Option<Vec<&str>>>> = info
            .get("CFBundleURLTypes")
            .map_or(Some(Vec::new()), |types| types.as_array().map(|types| {
                types
                    .iter()
                    .map(|item| string_list(item.as_dictionary().and_then(|item| item.get("CFBundleURLSchemes"))))
                    .collect()
            }));
        report.check(schemes == Some(vec![Some(vec!["mio"])]), "Länkschemat mio://");
        report.check(string_list(info.get("UIBackgroundModes")) == Some(vec!["audio", "processing"]), "Bakgrundsläget audio bevarat");
        report.check(info.get("NSSupportsLiveActivities").and_then(Plist::as_boolean) == Some(true), "Live Activity tillåten");
        report.check(
            string_list(info.get("BGTaskSchedulerPermittedIdentifiers")) == Some(vec!["app.mio.assistant.lesson-notes.*", "app.mio.assistant.backup"]),
            "Fortsatt bakgrundsbearbetning för lektionsanteckningar tillåten",
        );
        let arbitrary = info
            .get("NSAppTransportSecurity")
            .and_then(Plist::as_dictionary)
            .and_then(|security| security.get("NSAllowsArbitraryLoads"));
        report.check(!truthy(arbitrary), "Ingen generell HTTP-exception");
    }
    let privacy = read_plist(&root.join("Mio/PrivacyInfo.xcprivacy"))?;
    let types = privacy
        .as_dictionary()
        .and_then(|privacy| privacy.get("NSPrivacyAccessedAPITypes"))
        .ok_or_else(|| key_error("NSPrivacyAccessedAPITypes"))?;
    let mut reasons: HashMap<String, Plist> = HashMap::new();
    for item in types.as_array().map(Vec::as_slice).unwrap_or_default() {
        let item = item.as_dictionary().ok_or_else(|| key_error("NSPrivacyAccessedAPIType"))?;
        let kind = item.get("NSPrivacyAccessedAPIType").ok_or_else(|| key_error("NSPrivacyAccessedAPIType"))?;
        let reason = item.get("NSPrivacyAccessedAPITypeReasons").ok_or_else(|| key_error("NSPrivacyAccessedAPITypeReasons"))?;
        reasons.insert(kind.as_string().unwrap_or_default().to_owned(), reason.clone());
    }
    let declared = match reasons.get("NSPrivacyAccessedAPICategoryUserDefaults") {
        Some(Plist::Array(items)) => items.iter().any(|item| item.as_string() == Some("CA92.1")),
        Some(Plist::String(text)) => text.contains("CA92.1"),
        _ => false,
    };
    report.check(declared, "UserDefaults deklarerad för egna inställningar");
    let mut project_files = Vec::new();
    walk(&root.join("Mio.xcodeproj"), &[], &mut project_files);
    for path in project_files {
        let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
        let extension = path.extension().and_then(|extension| extension.to_str()).unwrap_or_default();
        if matches!(extension, "xcscheme" | "xcsettings") || name == "contents.xcworkspacedata" {
            let text = read_text(&path)?;
            let options = roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() };
            roxmltree::Document::parse_with_options(&text, options)
                .map_err(|error| Fatal(format!("{}: {error}", path.display())))?;
        }
    }
    report.check(
        project.matches("PRODUCT_BUNDLE_IDENTIFIER = app.mio.assistant;").count() == 2,
        "Appidentiteten app.mio.assistant i Debug och Release",
    );
    // One version for the whole repo (user's decision 2026-11-21): VERSION is the source, and the
    // app, the widgets, the gateway, Mio Kontroll, the verifier and Pianissimo must all carry it.
    let version = read_text(&root.join("VERSION"))?.trim().to_owned();
    report.check(
        pattern(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$").is_match(&version),
        format!("VERSION är X.Y.Z ({version})"),
    );
    report.check(
        project.matches(&format!("MARKETING_VERSION = {version};")).count() == 4
            && project.matches("MARKETING_VERSION = ").count() == 4,
        format!("Version {version} i appens och widgettilläggets Debug och Release"),
    );
    let manifest_version = pattern(r#"(?m)^version = "([^"]+)""#);
    let mut stale = Vec::new();
    for manifest in ["server/Cargo.toml", "control/Cargo.toml", "tools/Cargo.toml", "transcription-server/pyproject.toml"] {
        let text = read_text(&root.join(manifest))?;
        let found = manifest_version.captures(&text).map(|captures| captures[1].to_owned());
        if found.as_deref() != Some(version.as_str()) {
            stale.push(format!("{manifest} ({})", found.unwrap_or_else(|| "saknas".to_owned())));
        }
    }
    report.check(
        stale.is_empty(),
        if stale.is_empty() {
            format!("Version {version} i gatewayen, Mio Kontroll, verifieraren och Pianissimo")
        } else {
            format!("Version {version} saknas i {}", stale.join(", "))
        },
    );
    let mut targets: Vec<&str> = pattern(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);")
        .captures_iter(&project)
        .map(|captures| captures.get(1).expect("group").as_str())
        .collect();
    targets.sort_unstable();
    targets.dedup();
    report.check(targets == ["27.0"], "Minst iOS 27.0");
    report.check(
        project.matches("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;").count() == 2,
        "AppIcon vald i Debug och Release",
    );
    report.check(
        object_body(&project, "810000000000000000000001").contains("Assets.xcassets in Resources"),
        "Bildkatalogen ingår i appens resurser",
    );
    let icon_folder = root.join("Mio/Assets.xcassets/AppIcon.appiconset");
    let contents: Value = serde_json::from_str(&read_text(&icon_folder.join("Contents.json"))?)?;
    let icons = contents.get("images").ok_or_else(|| key_error("images"))?;
    let icons = icons.as_array().map(Vec::as_slice).unwrap_or_default();
    report.check(icons.len() == 3, "Appikon för ljust, mörkt och tonat läge");
    for icon in icons {
        let filename = icon.get("filename").ok_or_else(|| key_error("filename"))?;
        let filename = filename.as_str().map_or_else(|| filename.to_string(), str::to_owned);
        let path = icon_folder.join(&filename);
        let data = std::fs::read(&path).map_err(|error| Fatal(format!("{}: {error}", path.display())))?;
        let size = |range: std::ops::Range<usize>| data.get(range).map(|bytes| u32::from_be_bytes(bytes.try_into().expect("4 bytes")));
        let valid = data.starts_with(b"\x89PNG\r\n\x1a\n")
            && size(16..20) == Some(1024)
            && size(20..24) == Some(1024)
            && data.get(25) == Some(&2);
        report.check(valid, format!("{filename}: 1024 × 1024, RGB utan alfakanal"));
    }
    let content_repository = read_text(&root.join("Mio/Services/MioContentRepository.swift"))?;
    let sessions_repository = read_text(&root.join("Mio/Services/SessionRepository.swift"))?;
    report.check(
        content_repository.contains("\"Mio\"") && content_repository.contains("\"content-v1.json\""),
        "Innehållslagring under Mio",
    );
    report.check(
        sessions_repository.contains("\"Mio\"") && sessions_repository.contains("\"sessions.json\""),
        "Sessionslagring under Mio",
    );
    let link = pattern(r"\]\(([^)]+)\)");
    let mut documents = vec![root.join("README.md"), root.join("CLAUDE.md"), root.join("CHANGELOG.md")];
    documents.extend(glob_one_level(&root.join("docs"), ".md"));
    documents.extend(glob_one_level(&root.join("server"), ".md"));
    for path in documents {
        let text = read_text(&path)?;
        for captures in link.captures_iter(&text) {
            let target = &captures[1];
            if target.contains("://") || target.starts_with('#') {
                continue;
            }
            let target = target.split('#').next().unwrap_or_default();
            let parent = path.parent().unwrap_or(root);
            report.check(parent.join(target).exists(), format!("Länk {} → {target}", relative(root, &path)));
        }
    }
    for name in ["build-unsigned-ipa.yml", "verify-linux.yml"] {
        let text = read_text(&root.join(".github/workflows").join(name))?;
        let workflow = match load_yaml(&text) {
            Ok(workflow) => workflow,
            Err(error) => {
                report.errors.push(format!("Ogiltig YAML i .github/workflows/{name}: {error}"));
                continue;
            }
        };
        report.check(workflow.is_object(), format!(".github/workflows/{name}: giltig YAML-mappning"));
        let issues = workflow_contract_issues(name, &workflow);
        if issues.is_empty() {
            report.check(true, format!(".github/workflows/{name}: säkerhetskritiska jobbinställningar"));
        } else {
            report.errors.extend(issues.iter().map(|issue| format!(".github/workflows/{name}: {issue}")));
        }
        let jobs = workflow.get("jobs").and_then(Value::as_object);
        for job in jobs.into_iter().flat_map(|jobs| jobs.values()) {
            let steps = job.get("steps").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
            for step in steps.iter().filter_map(Value::as_object) {
                let Some(run) = step.get("run") else { continue };
                let step_name = match step.get("name") {
                    Some(Value::String(text)) => text.clone(),
                    Some(other) => other.to_string(),
                    None => "namnlöst steg".to_owned(),
                };
                let valid = run.as_str().is_some_and(bash_syntax_ok);
                report.check(valid, format!("Bash-syntax: {name}: {step_name}"));
            }
        }
    }
    // gpui-kit breaks its API weekly; the control panel must pin one exact version.
    let control = read_text(&root.join("control/Cargo.toml"))?;
    report.check(
        pattern(r#"(?m)^gpui-kit = \{ version = "=\d+\.\d+\.\d+" \}"#).is_match(&control),
        "control/Cargo.toml: gpui-kit låst till en exakt version",
    );
    let diff = Command::new("git")
        .args(["diff", "--check"])
        .current_dir(root)
        .stdin(Stdio::null())
        .output()?;
    report.check(diff.status.success(), "git diff --check");
    let skip = ["node_modules", ".wrangler", "dist", "target", ".venv", "__pycache__", ".pytest_cache", ".git"];
    let root_has_git = root.components().any(|part| part.as_os_str() == ".git");
    for folder in ["Mio", "MioTests", "MioUITests", "MioWidgets", "server", "transcription-server", "tools", "control", "docs"] {
        let mut files = Vec::new();
        walk(&root.join(folder), &skip, &mut files);
        for path in files {
            let extension = path.extension().and_then(|extension| extension.to_str()).unwrap_or_default();
            if root_has_git || !path.is_file() || !matches!(extension, "swift" | "md" | "rs" | "toml" | "py" | "json") {
                continue;
            }
            for (index, line) in splitlines(&read_text(&path)?).into_iter().enumerate() {
                if has_trailing_whitespace(line) {
                    report.errors.push(format!("Trailing whitespace: {}:{}", relative(root, &path), index + 1));
                }
            }
        }
    }
    Ok(())
}

fn bash_syntax_ok(script: &str) -> bool {
    let child = Command::new("bash")
        .arg("-n")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else { return false };
    if let Some(mut stdin) = child.stdin.take() {
        // A syntax error can make bash exit before reading everything; the exit code decides.
        let _ = stdin.write_all(script.as_bytes());
    }
    child.wait().is_ok_and(|status| status.success())
}

pub fn run(arguments: &[String]) -> u8 {
    if let Some(argument) = arguments.first() {
        if argument == "-h" || argument == "--help" {
            println!("usage: mio-verify project\n\nPortable structural checks; this does not compile Swift or run XCTest.");
            return 0;
        }
        eprintln!("mio-verify project: error: unrecognized arguments: {}", arguments.join(" "));
        return 2;
    }
    match check_project(&root()) {
        Ok(report) => {
            if !report.errors.is_empty() {
                let lines: Vec<String> = report.errors.iter().map(|error| format!("FEL: {error}")).collect();
                println!("{}", lines.join("\n"));
            }
            println!(
                "{} strukturella kontroller godkända, {} fel. Ingen Swift-kompilering eller XCTest utförd.",
                report.checks.len(),
                report.errors.len()
            );
            u8::from(!report.errors.is_empty())
        }
        Err(error) => {
            eprintln!("Kontrollen kunde inte slutföras: {error}");
            1
        }
    }
}
