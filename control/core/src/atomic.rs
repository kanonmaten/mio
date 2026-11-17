//! Writing a settings file so that a crash or power loss leaves either the old or the new file,
//! never half of one. The previous version is kept next to it as `<name>.bak`.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    path.with_file_name(name)
}

/// The backup written by [`write_atomic`].
pub fn backup_path(path: &Path) -> PathBuf {
    sibling(path, ".bak")
}

/// Replaces `path` with `contents`: temporary file, fsync, rename, fsync of the directory.
///
/// An existing file keeps its owner, group and mode (the vocabulary file is
/// `root:mio-transcription 0640`, `gateway.env` is root-only `0600`) and is first copied to
/// `<name>.bak` with the same owner and mode. A new file gets `new_mode`.
pub fn write_atomic(path: &Path, contents: &[u8], new_mode: u32) -> std::io::Result<()> {
    let directory = path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let existing = std::fs::metadata(path).ok();
    let mode = existing.as_ref().map_or(new_mode, |metadata| metadata.permissions().mode() & 0o7777);
    let owner = existing.as_ref().map(|metadata| (metadata.uid(), metadata.gid()));
    if existing.is_some() {
        let backup = backup_path(path);
        write_file(&sibling(path, ".bak.tmp"), &std::fs::read(path)?, mode, owner)?;
        std::fs::rename(sibling(path, ".bak.tmp"), &backup)?;
    }
    let temporary = sibling(path, ".tmp");
    write_file(&temporary, contents, mode, owner)?;
    std::fs::rename(&temporary, path)?;
    File::open(directory)?.sync_all()
}

fn write_file(path: &Path, contents: &[u8], mode: u32, owner: Option<(u32, u32)>) -> std::io::Result<()> {
    // Created with the final mode, so a secret is never readable by others, not even briefly.
    let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(mode).open(path)?;
    if let Some((uid, gid)) = owner {
        // Only root can give a file away; as another user the owner is already the caller.
        if std::os::unix::fs::fchown(&file, Some(uid), Some(gid)).is_err() && running_as_root() {
            return Err(std::io::Error::other("kunde inte behålla filens ägare"));
        }
    }
    file.set_permissions(std::fs::Permissions::from_mode(mode))?;
    file.write_all(contents)?;
    file.sync_all()
}

/// Whether this process runs as root, from `/proc/self/status` (no libc needed).
fn running_as_root() -> bool {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| status.lines().find(|line| line.starts_with("Uid:")).map(str::to_owned))
        .is_some_and(|line| line.split_whitespace().nth(2) == Some("0"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_file_gets_the_requested_mode_and_no_backup() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway.env");
        write_atomic(&path, b"A=1\n", 0o600).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"A=1\n");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(!backup_path(&path).exists());
    }

    #[test]
    fn a_replaced_file_keeps_its_mode_and_leaves_the_old_version_as_backup() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("ordlista.txt");
        std::fs::write(&path, b"gammal\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        write_atomic(&path, b"ny\n", 0o600).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"ny\n");
        assert_eq!(std::fs::read(backup_path(&path)).unwrap(), b"gammal\n");
        for written in [path.clone(), backup_path(&path)] {
            assert_eq!(std::fs::metadata(&written).unwrap().permissions().mode() & 0o777, 0o640);
        }
        let leftovers: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
    }
}
