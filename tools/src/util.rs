//! Small helpers that reproduce the Python standard-library behaviour the gate relied on.

use std::ffi::OsStr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::time::{SystemTime, UNIX_EPOCH};

/// The repository root: the parent of this crate's directory.
pub fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tools/ lives inside the repository")
        .to_path_buf()
}

/// The Swift compiler the harnesses use; `SWIFT_EXECUTABLE` overrides `swiftc`.
pub fn swift_executable_name() -> String {
    std::env::var("SWIFT_EXECUTABLE").unwrap_or_else(|_| "swiftc".to_owned())
}

/// `shutil.which`: a name with a slash is checked as a path, otherwise `PATH` is searched.
pub fn which(name: &str) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    if name.contains('/') {
        let path = Path::new(name);
        return is_executable(path).then(|| path.to_path_buf());
    }
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Python's `str.splitlines()`: it also breaks on \v, \f, \x1c–\x1e, U+0085, U+2028 and U+2029,
/// and treats \r\n as one break. The trailing-whitespace check numbers lines the same way.
pub fn splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        if matches!(
            character,
            '\n' | '\r' | '\x0b' | '\x0c' | '\x1c' | '\x1d' | '\x1e' | '\u{85}' | '\u{2028}' | '\u{2029}'
        ) {
            lines.push(&text[start..index]);
            let mut end = index + character.len_utf8();
            if character == '\r' && text[end..].starts_with('\n') {
                characters.next();
                end += 1;
            }
            start = end;
        }
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// Python's `str.isspace()` for one character: Unicode White_Space plus \x1c–\x1f.
pub fn is_python_space(character: char) -> bool {
    character.is_whitespace() || ('\x1c'..='\x1f').contains(&character)
}

/// `line != line.rstrip()`.
pub fn has_trailing_whitespace(line: &str) -> bool {
    line.chars().next_back().is_some_and(is_python_space)
}

/// `str.strip()`.
pub fn python_strip(text: &str) -> &str {
    text.trim_matches(is_python_space)
}

/// `datetime.now(timezone.utc).isoformat()`, e.g. `2026-11-17T07:43:34.734705+00:00`.
pub fn utc_now_iso() -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let seconds = now.as_secs() as i64;
    let micros = now.subsec_micros();
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let of_day = seconds.rem_euclid(86_400);
    let time = format!("{:02}:{:02}:{:02}", of_day / 3600, of_day % 3600 / 60, of_day % 60);
    // isoformat() leaves out the fraction when it is exactly zero.
    let fraction = if micros == 0 { String::new() } else { format!(".{micros:06}") };
    format!("{year:04}-{month:02}-{day:02}T{time}{fraction}+00:00")
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * shifted_month + 2) / 5 + 1) as u32;
    let month = if shifted_month < 10 { shifted_month + 3 } else { shifted_month - 9 } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// A command the way Python's CalledProcessError prints it: `['swiftc', '--version']`.
pub fn command_repr(command: &Command) -> String {
    let quote = |part: &OsStr| format!("'{}'", part.to_string_lossy());
    let parts: Vec<String> = std::iter::once(command.get_program())
        .chain(command.get_args())
        .map(quote)
        .collect();
    format!("[{}]", parts.join(", "))
}

/// `subprocess.run(..., check=True)` with inherited output.
pub fn run_checked(command: &mut Command) -> Result<(), String> {
    let status = command.status().map_err(|error| error.to_string())?;
    check_status(command, status)
}

pub fn check_status(command: &Command, status: ExitStatus) -> Result<(), String> {
    if status.success() {
        return Ok(());
    }
    let repr = command_repr(command);
    Err(match status.code() {
        Some(code) => format!("Command '{repr}' returned non-zero exit status {code}."),
        None => {
            use std::os::unix::process::ExitStatusExt;
            format!("Command '{repr}' died with signal {}.", status.signal().unwrap_or(0))
        }
    })
}

/// Turns a possibly relative path into an absolute one, resolving symlinks in the existing
/// part, like `Path.resolve()` on a path that may not exist yet.
pub fn resolve(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    if let Ok(resolved) = absolute.canonicalize() {
        return resolved;
    }
    match (absolute.parent(), absolute.file_name()) {
        (Some(parent), Some(name)) => resolve(parent).join(name),
        _ => absolute,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitlines_matches_python() {
        assert_eq!(splitlines(""), Vec::<&str>::new());
        assert_eq!(splitlines("a\n"), ["a"]);
        assert_eq!(splitlines("a\r\nb\rc\n\nd"), ["a", "b", "c", "", "d"]);
        assert_eq!(splitlines("a\u{2028}b\u{85}c\x0cd"), ["a", "b", "c", "d"]);
    }

    #[test]
    fn trailing_whitespace_uses_python_spaces() {
        assert!(has_trailing_whitespace("x "));
        assert!(has_trailing_whitespace("x\u{a0}"));
        assert!(has_trailing_whitespace("x\x1f"));
        assert!(!has_trailing_whitespace("x\u{200b}"));
        assert!(!has_trailing_whitespace(""));
    }

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_774), (2026, 11, 17));
        assert_eq!(civil_from_days(11_016), (2000, 2, 29));
    }
}
