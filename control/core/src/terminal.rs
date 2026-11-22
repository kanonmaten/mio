//! The default terminal, for the scripts that must run in one (the installers ask for `sudo`).
//!
//! On KDE Plasma the default is the one chosen in Systeminställningar, which Plasma stores as a
//! desktop entry ID (`TerminalService` in `kdeglobals`). That entry is started the way the
//! freedesktop terminal spec describes: its `Exec`, then its `X-TerminalArgExec` (default `-e`),
//! then the command. Elsewhere, or when Plasma names nothing usable, `xdg-terminal-exec` picks the
//! terminal. No terminal is named in the code, and no terminal-specific "hold" flag is needed:
//! the script waits for Enter itself (see `updates::script`).
//!
//! The command handed to the terminal is always one word, the path of an executable script:
//! some terminals take everything after `-e` as the command and its arguments (Konsole,
//! Ghostty), others only the next argument (Xfce Terminal), and one word works in both.

use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};

use crate::computer::config_home;

/// The program and arguments that open the default terminal running `command`.
#[derive(Debug, PartialEq, Eq)]
pub struct Launch {
    pub program: String,
    pub args: Vec<String>,
}

/// Writes `script` to a new private executable file that deletes itself when it starts, and
/// returns how to open the default terminal running it.
pub fn launch_script(script: &str) -> std::io::Result<Launch> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).filter(|dir| dir.is_absolute()).unwrap_or_else(std::env::temp_dir);
    let path = write_script(&dir, script)?;
    Ok(launch(&[&path.to_string_lossy()]))
}

/// `script` as `<dir>/mio-kontroll-<pid>-<nanos>.sh`, mode 0700, never over an existing file.
pub fn write_script(dir: &Path, script: &str) -> std::io::Result<PathBuf> {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|time| time.as_nanos()).unwrap_or(0);
    let path = dir.join(format!("mio-kontroll-{}-{nanos}.sh", std::process::id()));
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o700).open(&path)?;
    // bash has the file open once it runs, so removing it first leaves nothing behind.
    file.write_all(format!("#!/usr/bin/env bash\nrm -f -- \"$0\"\n{script}").as_bytes())?;
    Ok(path)
}

/// How to open the default terminal for `command` on this computer.
pub fn launch(command: &[&str]) -> Launch {
    let kde = std::env::var("XDG_CURRENT_DESKTOP").is_ok_and(|desktops| desktops.split(':').any(|name| name.eq_ignore_ascii_case("KDE")));
    let entry = kde
        .then(|| config_home().and_then(|config| std::fs::read_to_string(config.join("kdeglobals")).ok()))
        .flatten()
        .and_then(|globals| kde_terminal_service(&globals))
        .and_then(|id| find_entry(&id, &data_dirs()))
        .and_then(|path| std::fs::read_to_string(path).ok());
    resolve(entry.as_deref(), command)
}

/// The entry's command when it has a usable one, otherwise `xdg-terminal-exec`.
pub fn resolve(entry: Option<&str>, command: &[&str]) -> Launch {
    let mut argv = entry.and_then(entry_command).unwrap_or_else(|| vec!["xdg-terminal-exec".to_owned()]);
    if argv.len() == 1 && argv[0] == "xdg-terminal-exec" {
        // Its own options end at `--`; everything after is the command.
        argv.push("--".to_owned());
    }
    argv.extend(command.iter().map(|part| (*part).to_owned()));
    let program = argv.remove(0);
    Launch { program, args: argv }
}

/// `TerminalService` under `[General]` in `kdeglobals`: the desktop entry ID Plasma's
/// "Standardterminal" setting writes.
pub fn kde_terminal_service(kdeglobals: &str) -> Option<String> {
    ini_value(kdeglobals, "General", "TerminalService")
        .filter(|id| id.ends_with(".desktop") && !id.contains('/'))
        .map(str::to_owned)
}

/// `Exec` plus the execution argument from a terminal's desktop entry, or `None` when the entry is
/// hidden or has no `Exec`.
pub fn entry_command(entry: &str) -> Option<Vec<String>> {
    let group = "Desktop Entry";
    if ini_value(entry, group, "Hidden") == Some("true") {
        return None;
    }
    let mut argv = parse_exec(&unescape_string(ini_value(entry, group, "Exec")?))?;
    let exec_arg = ini_value(entry, group, "X-TerminalArgExec").or_else(|| ini_value(entry, group, "TerminalArgExec"));
    match exec_arg {
        // An explicitly empty key means the command follows directly.
        Some("") => {}
        Some(arg) => argv.push(arg.to_owned()),
        None => argv.push("-e".to_owned()),
    }
    Some(argv)
}

/// A desktop entry string value with its escapes (`\\s`, `\\n`, `\\t`, `\\r`, `\\\\`) decoded; the spec
/// decodes these before the `Exec` quoting rules apply.
pub fn unescape_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(char) = chars.next() {
        if char != '\\' {
            out.push(char);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Splits an `Exec` value as the Desktop Entry spec says: double quotes group, a backslash
/// escapes `"`, `` ` ``, `$` and `\` inside them, and field codes (`%f`, `%U`, …) are dropped,
/// with `%%` meaning `%`. Returns `None` for an unterminated quote or an empty command.
pub fn parse_exec(exec: &str) -> Option<Vec<String>> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut started = false;
    let mut chars = exec.chars().peekable();
    while let Some(char) = chars.next() {
        match char {
            '"' => {
                started = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => current.push(chars.next()?),
                        other => current.push(other),
                    }
                }
            }
            ' ' | '\t' => {
                if started {
                    args.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            // A field code (`%f`, `%U`, …) stands for nothing here: no file or URL is passed.
            '%' => {
                if chars.next() == Some('%') {
                    current.push('%');
                    started = true;
                }
            }
            other => {
                current.push(other);
                started = true;
            }
        }
    }
    if started {
        args.push(current);
    }
    (!args.is_empty()).then_some(args)
}

/// The first entry with desktop file ID `id` under the XDG data directories, in their order. An
/// entry in a subdirectory has its path's `/` turned into `-` in its ID (`kde/foo.desktop` is
/// `kde-foo.desktop`).
pub fn find_entry(id: &str, data_dirs: &[PathBuf]) -> Option<PathBuf> {
    data_dirs.iter().find_map(|dir| find_in(&dir.join("applications"), "", id, 0))
}

fn find_in(dir: &Path, prefix: &str, id: &str, depth: u8) -> Option<PathBuf> {
    let direct = dir.join(id.strip_prefix(prefix)?);
    if direct.is_file() {
        return Some(direct);
    }
    if depth >= 3 {
        return None;
    }
    let mut subdirs: Vec<_> = std::fs::read_dir(dir).ok()?.flatten().filter(|entry| entry.path().is_dir()).collect();
    subdirs.sort_by_key(std::fs::DirEntry::file_name);
    subdirs.into_iter().find_map(|entry| {
        let name = entry.file_name().into_string().ok()?;
        find_in(&entry.path(), &format!("{prefix}{name}-"), id, depth + 1)
    })
}

/// `$XDG_DATA_HOME` (or `~/.local/share`) followed by `$XDG_DATA_DIRS` (or
/// `/usr/local/share:/usr/share`).
fn data_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
    let system = std::env::var("XDG_DATA_DIRS").ok().filter(|dirs| !dirs.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".to_owned());
    home.into_iter()
        .chain(system.split(':').map(PathBuf::from).filter(|path| path.is_absolute()))
        .collect()
}

/// A value from an INI-style file (desktop entries, `kdeglobals`). Keys with a locale or KDE's
/// `[$e]` suffix are not the plain key and are skipped.
fn ini_value<'a>(text: &'a str, group: &str, key: &str) -> Option<&'a str> {
    let mut in_group = false;
    for line in text.lines() {
        let line = line.trim();
        if let Some(name) = line.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')) {
            in_group = name == group;
        } else if in_group
            && let Some((name, value)) = line.split_once('=')
            && name.trim() == key
        {
            return Some(value.trim());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt as _;

    use super::*;

    const GHOSTTY: &str = "[Desktop Entry]\nName=Ghostty\nExec=ghostty --gtk-single-instance=true\nX-TerminalArgExec=-e\nX-TerminalArgHold=--wait-after-command\n\n[Desktop Action new-window]\nExec=ghostty --other\n";

    #[test]
    fn plasma_s_default_terminal_runs_the_command_through_its_entry() {
        let launch = resolve(Some(GHOSTTY), &["bash", "-c", "echo hej"]);
        assert_eq!(launch.program, "ghostty");
        assert_eq!(launch.args, ["--gtk-single-instance=true", "-e", "bash", "-c", "echo hej"]);
    }

    #[test]
    fn without_a_usable_entry_xdg_terminal_exec_chooses() {
        for entry in [None, Some("[Desktop Entry]\nName=Trasig\n"), Some("[Desktop Entry]\nExec=x\nHidden=true\n")] {
            let launch = resolve(entry, &["bash", "-c", "x"]);
            assert_eq!(launch.program, "xdg-terminal-exec");
            assert_eq!(launch.args, ["--", "bash", "-c", "x"]);
        }
    }

    #[test]
    fn the_execution_argument_follows_the_entry() {
        assert_eq!(entry_command("[Desktop Entry]\nExec=konsole\n").unwrap(), ["konsole", "-e"]);
        assert_eq!(entry_command("[Desktop Entry]\nExec=kitty\nX-TerminalArgExec=\n").unwrap(), ["kitty"]);
        assert_eq!(entry_command("[Desktop Entry]\nExec=foot\nTerminalArgExec=--\n").unwrap(), ["foot", "--"]);
    }

    #[test]
    fn kdeglobals_names_the_entry_only_under_general() {
        let globals = "[KDE]\nTerminalService=fel.desktop\n\n[General]\nTerminalApplication=ghostty --gtk-single-instance=true\nTerminalService=com.mitchellh.ghostty.desktop\n";
        assert_eq!(kde_terminal_service(globals).as_deref(), Some("com.mitchellh.ghostty.desktop"));
        assert_eq!(kde_terminal_service("[General]\nTerminalService=../evil.desktop\n"), None);
        assert_eq!(kde_terminal_service("[General]\nTerminalApplication=konsole\n"), None);
    }

    #[test]
    fn the_terminal_gets_one_word_a_self_deleting_script() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_script(dir.path(), "echo hej\n").unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("#!/usr/bin/env bash\nrm -f -- \"$0\"\necho hej"));
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o700);
        let output = std::process::Command::new(&path).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hej\n");
        assert!(!path.exists(), "the script removes itself");
        let launch = resolve(Some(GHOSTTY), &[&path.to_string_lossy()]);
        assert_eq!(launch.args.len(), 3, "Exec, -e and the one path");
    }

    #[test]
    fn exec_is_string_decoded_before_its_quoting() {
        let entry = "[Desktop Entry]\nExec=\"/home/a\\\\$b/term\"\\sx\n";
        assert_eq!(entry_command(entry).unwrap(), ["/home/a$b/term", "x", "-e"]);
    }

    #[test]
    fn an_entry_in_a_subdirectory_is_found_by_its_id() {
        let data = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(data.path().join("applications/kde")).unwrap();
        std::fs::write(data.path().join("applications/kde/term.desktop"), GHOSTTY).unwrap();
        let dirs = [data.path().to_path_buf()];
        assert_eq!(find_entry("kde-term.desktop", &dirs), Some(data.path().join("applications/kde/term.desktop")));
        assert_eq!(find_entry("term.desktop", &dirs), None);
    }

    #[test]
    fn exec_follows_the_desktop_entry_quoting() {
        assert_eq!(parse_exec(r#"term --title "Mio \"Kontroll\"" %U 100%%"#).unwrap(), ["term", "--title", r#"Mio "Kontroll""#, "100%"]);
        assert_eq!(parse_exec(r#"a "" b"#).unwrap(), ["a", "", "b"]);
        assert_eq!(parse_exec(r#"a "open"#), None);
        assert_eq!(parse_exec("%F"), None);
    }

    #[test]
    fn the_entry_is_looked_up_in_data_dir_order() {
        let home = tempfile::tempdir().unwrap();
        let system = tempfile::tempdir().unwrap();
        for dir in [&home, &system] {
            std::fs::create_dir_all(dir.path().join("applications")).unwrap();
        }
        std::fs::write(system.path().join("applications/t.desktop"), GHOSTTY).unwrap();
        let dirs = [home.path().to_path_buf(), system.path().to_path_buf()];
        assert_eq!(find_entry("t.desktop", &dirs), Some(system.path().join("applications/t.desktop")));
        std::fs::write(home.path().join("applications/t.desktop"), GHOSTTY).unwrap();
        assert_eq!(find_entry("t.desktop", &dirs), Some(home.path().join("applications/t.desktop")));
        assert_eq!(find_entry("saknas.desktop", &dirs), None);
    }
}
