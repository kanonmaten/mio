//! Uppdateringar: which parts of Mio are behind the repo, and the script that updates them.
//!
//! Each installer records the commit it was installed from (`commit` next to the program). A part
//! is behind when its directory changed between that commit and the repo's upstream. The updates
//! run in the default terminal as the user, because the installers ask for `sudo` themselves and must never run
//! as root from files the user can edit.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Part {
    Repo,
    Gateway,
    Pianissimo,
    Model,
    Panel,
    System,
}

impl Part {
    pub const ALL: [Part; 6] = [Part::Repo, Part::Gateway, Part::Pianissimo, Part::Model, Part::Panel, Part::System];

    pub fn id(self) -> &'static str {
        match self {
            Part::Repo => "repo",
            Part::Gateway => "gateway",
            Part::Pianissimo => "pianissimo",
            Part::Model => "model",
            Part::Panel => "panel",
            Part::System => "system",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Part::Repo => "Mio-repot",
            Part::Gateway => "AI-gatewayen",
            Part::Pianissimo => "Pianissimos serverkod",
            Part::Model => "Pianissimo-modellen",
            Part::Panel => "Mio Kontroll",
            Part::System => "Systempaket",
        }
    }

    /// The repo directory and the installed commit file of the parts built from the repo.
    fn installed_from(self) -> Option<(&'static str, &'static str)> {
        match self {
            Part::Gateway => Some(("server", "opt/mio-gateway/commit")),
            Part::Pianissimo => Some(("transcription-server", "opt/mio-transcription/commit")),
            Part::Panel => Some(("control", "usr/local/lib/mio-control/commit")),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RepoState {
    pub head: String,
    /// New commits on the upstream branch after `git fetch`.
    pub behind: u32,
    /// Tracked files have changes; `git pull --ff-only` is refused then.
    pub dirty: bool,
    /// `git fetch` failed (offline); `behind` is from the last fetch.
    pub fetch_failed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PartState {
    UpToDate,
    Behind,
    NotInstalled,
    /// Installed, but which version is not known (installed before the commit was recorded).
    Unknown(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdateState {
    pub repo: Result<RepoState, String>,
    /// Gateway, Pianissimo and Panel.
    pub parts: Vec<(Part, PartState)>,
    pub system: Result<u32, String>,
}

impl UpdateState {
    pub fn part(&self, part: Part) -> Option<&PartState> {
        self.parts.iter().find(|(each, _)| *each == part).map(|(_, state)| state)
    }

    /// What "Uppdatera allt" runs: the pull, every part not known to be current, the model (it
    /// checks itself and does nothing when current) and the system packages when there are any.
    pub fn everything(&self) -> Vec<Part> {
        let mut steps = vec![Part::Repo];
        for (part, state) in &self.parts {
            if matches!(state, PartState::Behind | PartState::Unknown(_)) {
                steps.push(*part);
            }
        }
        if !matches!(self.part(Part::Pianissimo), None | Some(PartState::NotInstalled)) {
            steps.push(Part::Model);
        }
        if matches!(self.system, Ok(count) if count > 0) {
            steps.push(Part::System);
        }
        steps.sort_by_key(|part| Part::ALL.iter().position(|each| each == part));
        steps
    }

    /// Why nothing can be pulled, if so.
    pub fn blocked(&self) -> Option<String> {
        match &self.repo {
            Err(message) => Some(message.clone()),
            Ok(repo) if repo.dirty => Some("Mio-repot har ändringar som inte är sparade i git, så det uppdateras inte. Spara eller ångra dem först.".into()),
            Ok(_) => None,
        }
    }
}

/// What `git rev-parse --local-env-vars` lists: variables with which a calling git points every
/// git below it at its own repository. A pre-push hook in a linked worktree gets `GIT_DIR`, and
/// `-C <repo>` does not override it, so a child git would read or write the caller's repo.
const REPO_ENV: [&str; 15] = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
];

/// `git -C <repo>` without input or error output, and without an inherited repository.
fn git_command(repo: &Path) -> Command {
    let mut command = Command::new("git");
    for name in REPO_ENV {
        command.env_remove(name);
    }
    command.arg("-C").arg(repo).stdin(Stdio::null()).stderr(Stdio::null());
    command
}

fn git(repo: &Path, arguments: &[&str]) -> Option<String> {
    let output = git_command(repo).args(arguments).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn is_commit(text: &str) -> bool {
    text.len() == 40 && text.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Reads the repo and the installed commits. `root` is `/` except in tests.
pub fn probe(repo: &Path, root: &Path, fetch: bool) -> UpdateState {
    let repo_state = read_repo(repo, fetch);
    let target = git(repo, &["rev-parse", "@{upstream}"]).or_else(|| git(repo, &["rev-parse", "HEAD"]));
    let parts = [Part::Gateway, Part::Pianissimo, Part::Panel]
        .into_iter()
        .map(|part| (part, part_state(part, repo, root, target.as_deref())))
        .collect();
    UpdateState { repo: repo_state, parts, system: system_updates() }
}

fn read_repo(repo: &Path, fetch: bool) -> Result<RepoState, String> {
    let head = git(repo, &["rev-parse", "HEAD"]).ok_or_else(|| format!("Hittar inte Mio-repot i {}.", repo.display()))?;
    let fetch_failed = fetch && git(repo, &["fetch", "--quiet"]).is_none();
    let behind = git(repo, &["rev-list", "--count", "HEAD..@{upstream}"]).and_then(|count| count.parse().ok()).unwrap_or(0);
    let dirty = git(repo, &["status", "--porcelain", "--untracked-files=no"]).is_none_or(|changes| !changes.is_empty());
    Ok(RepoState { head, behind, dirty, fetch_failed })
}

fn part_state(part: Part, repo: &Path, root: &Path, target: Option<&str>) -> PartState {
    let Some((directory, stamp)) = part.installed_from() else { return PartState::Unknown(String::new()) };
    let stamp = root.join(stamp);
    let installed_dir = stamp.parent().map(Path::to_path_buf).unwrap_or_default();
    let Ok(text) = std::fs::read_to_string(&stamp) else {
        return if installed_dir.exists() {
            PartState::Unknown("installerad före versionsmärkningen; uppdatera en gång så syns den".into())
        } else {
            PartState::NotInstalled
        };
    };
    let installed = text.trim();
    let Some(target) = target.filter(|_| is_commit(installed)) else {
        return PartState::Unknown("okänd version".into());
    };
    let status = git_command(repo).args(["diff", "--quiet", installed, target, "--", directory]).status();
    match status.map(|status| status.code()) {
        Ok(Some(0)) => PartState::UpToDate,
        Ok(Some(1)) => PartState::Behind,
        _ => PartState::Unknown("installerad från en commit som inte finns i repot".into()),
    }
}

/// `checkupdates` (pacman-contrib) lists one package per line and exits 2 when there are none.
fn system_updates() -> Result<u32, String> {
    let output = Command::new("checkupdates")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| "checkupdates saknas. Installera pacman-contrib för att se systemuppdateringar.".to_owned())?;
    match output.status.code() {
        Some(0) => Ok(count_packages(&String::from_utf8_lossy(&output.stdout))),
        Some(2) => Ok(0),
        _ => Err("checkupdates kunde inte läsa paketlistan just nu.".into()),
    }
}

pub fn count_packages(text: &str) -> u32 {
    text.lines().filter(|line| !line.trim().is_empty()).count() as u32
}

/// Single-quotes `text` for bash.
pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// Where `transcription-server/install.sh` puts the model updater.
pub const UPDATE_MODEL: &str = "/opt/mio-transcription/update-model.sh";

/// The script the default terminal runs. It stops at the first error, says so, and waits for Enter
/// so the output stays visible in any terminal.
pub fn script(repo: &Path, steps: &[Part], keep_autostart: bool) -> String {
    let mut lines = vec![
        "set -euo pipefail".to_owned(),
        "step() { printf '\\n==> %s\\n' \"$1\"; }".to_owned(),
        "trap 'printf \"\\nStoppade vid ett fel. Stegen efter det här kördes inte.\\n\"' ERR".to_owned(),
        // Waiting here, on success and on failure alike, keeps the output readable in any terminal
        // without a terminal-specific "hold" flag.
        "trap 'printf \"\\nTryck på Enter för att stänga fönstret.\\n\"; read -r _ || true' EXIT".to_owned(),
        format!("cd {}", shell_quote(&repo.display().to_string())),
    ];
    for part in steps {
        lines.push(format!("step {}", shell_quote(part.title())));
        lines.push(match part {
            Part::Repo => "if ! git diff --quiet || ! git diff --cached --quiet; then echo 'FEL: Mio-repot har ändringar som inte är sparade i git. Inget uppdaterades.'; exit 1; fi\ngit pull --ff-only".to_owned(),
            Part::Gateway => "./server/install.sh".to_owned(),
            Part::Pianissimo => "./transcription-server/install.sh".to_owned(),
            Part::Model => format!("sudo {UPDATE_MODEL}"),
            Part::Panel if keep_autostart => "./control/install.sh".to_owned(),
            Part::Panel => "./control/install.sh --utan-autostart".to_owned(),
            Part::System => "sudo pacman -Syu".to_owned(),
        });
    }
    lines.push("step 'Klart'".to_owned());
    if steps.contains(&Part::Panel) {
        lines.push("echo 'Mio Kontroll är ny: välj Avsluta i ikonens meny och starta den igen.'".to_owned());
    }
    lines.join("\n") + "\n"
}

/// The repo the panel was built from; `control/install.sh` builds in place.
pub fn built_from() -> PathBuf {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    path.canonicalize().unwrap_or(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(directory: &Path, arguments: &[&str]) {
        let status = git_command(directory).args(arguments)
            .env("GIT_AUTHOR_NAME", "t").env("GIT_AUTHOR_EMAIL", "t@t").env("GIT_COMMITTER_NAME", "t").env("GIT_COMMITTER_EMAIL", "t@t")
            .stdout(Stdio::null()).stderr(Stdio::null()).status().unwrap();
        assert!(status.success(), "git {arguments:?}");
    }

    fn commit(directory: &Path, file: &str, text: &str) -> String {
        let path = directory.join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
        run(directory, &["add", "."]);
        run(directory, &["commit", "-q", "-m", file]);
        git(directory, &["rev-parse", "HEAD"]).unwrap()
    }

    #[test]
    fn a_part_is_behind_only_when_its_directory_changed_upstream() {
        behind_scenario();
    }

    /// A pre-push hook in a linked worktree runs with `GIT_DIR` (and friends) set to that repo,
    /// and `verify` runs these tests from it. The scenario is rerun in a child process with that
    /// environment pointing at a decoy repo, which must come out untouched.
    #[test]
    fn git_ignores_a_repo_inherited_from_a_calling_git() {
        const CHILD: &str = "MIO_TEST_INHERITED_GIT_DIR";
        if std::env::var_os(CHILD).is_some() {
            behind_scenario();
            return;
        }
        let temp = tempfile::tempdir().unwrap();
        let decoy = temp.path().join("decoy");
        std::fs::create_dir_all(&decoy).unwrap();
        run(&decoy, &["init", "-q", "-b", "main"]);
        let before = commit(&decoy, "README", "decoy");
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "updates::tests::git_ignores_a_repo_inherited_from_a_calling_git", "--test-threads=1"])
            .env(CHILD, "1")
            .env("GIT_DIR", decoy.join(".git"))
            .env("GIT_WORK_TREE", &decoy)
            .env("GIT_INDEX_FILE", decoy.join(".git/index"))
            .output()
            .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
        assert_eq!(git(&decoy, &["rev-parse", "HEAD"]), Some(before));
        assert_eq!(git(&decoy, &["config", "--get", "core.bare"]).as_deref(), Some("false"));
        assert_eq!(git(&decoy, &["status", "--porcelain"]).as_deref(), Some(""));
    }

    fn behind_scenario() {
        let temp = tempfile::tempdir().unwrap();
        let (origin, clone, root) = (temp.path().join("origin"), temp.path().join("clone"), temp.path().join("root"));
        std::fs::create_dir_all(&origin).unwrap();
        run(&origin, &["init", "-q", "-b", "main"]);
        let first = commit(&origin, "server/a.rs", "1");
        commit(&origin, "control/a.rs", "1");
        run(temp.path(), &["clone", "-q", origin.to_str().unwrap(), clone.to_str().unwrap()]);
        let installed = git(&clone, &["rev-parse", "HEAD"]).unwrap();
        for (stamp, commit) in [("opt/mio-gateway/commit", &first), ("usr/local/lib/mio-control/commit", &installed)] {
            std::fs::create_dir_all(root.join(stamp).parent().unwrap()).unwrap();
            std::fs::write(root.join(stamp), format!("{commit}\n")).unwrap();
        }
        // Upstream moves on in the gateway only.
        commit(&origin, "server/a.rs", "2");

        let state = probe(&clone, &root, true);
        let repo = state.repo.clone().unwrap();
        assert_eq!((repo.behind, repo.dirty, repo.fetch_failed), (1, false, false));
        assert_eq!(state.part(Part::Gateway), Some(&PartState::Behind));
        assert_eq!(state.part(Part::Panel), Some(&PartState::UpToDate));
        assert_eq!(state.part(Part::Pianissimo), Some(&PartState::NotInstalled));
        assert!(state.blocked().is_none());

        std::fs::write(clone.join("control/a.rs"), "local").unwrap();
        let state = probe(&clone, &root, false);
        assert!(state.repo.as_ref().unwrap().dirty);
        assert!(state.blocked().unwrap().contains("ändringar"));
        assert!(probe(&temp.path().join("nowhere"), &root, false).repo.is_err());
    }

    #[test]
    fn everything_runs_what_is_not_current_in_order() {
        let state = UpdateState {
            repo: Ok(RepoState { head: "x".into(), behind: 2, dirty: false, fetch_failed: false }),
            parts: vec![
                (Part::Gateway, PartState::Behind),
                (Part::Pianissimo, PartState::UpToDate),
                (Part::Panel, PartState::Unknown("okänd version".into())),
            ],
            system: Ok(3),
        };
        assert_eq!(state.everything(), [Part::Repo, Part::Gateway, Part::Model, Part::Panel, Part::System]);
        let quiet = UpdateState { parts: vec![(Part::Pianissimo, PartState::NotInstalled)], system: Ok(0), ..state };
        assert_eq!(quiet.everything(), [Part::Repo]);
    }

    #[test]
    fn the_script_stops_at_the_first_error_and_quotes_the_path() {
        let script = script(Path::new("/home/a b/it's/Mio"), &[Part::Repo, Part::Gateway, Part::Panel, Part::System], false);
        assert!(script.starts_with("set -euo pipefail\n"));
        assert!(script.contains("cd '/home/a b/it'\\''s/Mio'\n"));
        let order: Vec<usize> = ["git pull --ff-only", "./server/install.sh", "./control/install.sh --utan-autostart", "sudo pacman -Syu"]
            .iter()
            .map(|needle| script.find(needle).expect(needle))
            .collect();
        assert!(order.is_sorted());
        assert!(!script.contains("transcription-server"));
        assert!(script.contains("starta den igen"));
        assert!(script.contains("read -r _ || true' EXIT"), "waits for Enter in any terminal");
        let output = Command::new("bash").args(["-n", "-c", &script]).status().unwrap();
        assert!(output.success(), "bash accepts the script");
        assert_eq!(count_packages("linux 6.1 -> 6.2\n\nmesa 1 -> 2\n"), 2);
    }
}
