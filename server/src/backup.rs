//! The nightly backup from the phone (contract "Säkerhetskopian" in docs/DATAMODELL.md).
//!
//! The app sends its versioned JSON export over Tailscale; the gateway only checks that it is
//! a JSON object with `schemaVersion` 2 and `exportedAt`, never interprets it, never logs it and
//! never sends it to a provider. Each copy is encrypted with XChaCha20-Poly1305 under a key in
//! the state directory and written through a temporary file that is renamed when complete. The
//! 14 newest copies are kept. The key lies on the same encrypted disk as the copies: it protects
//! copies moved or backed up further from the directory, not against root on the PC.
//!
//! File format, all of it written by this module: `MIOBAK01` (8 bytes, also the associated
//! data), a 24-byte random nonce, the ciphertext (as long as the export) and the 16-byte tag.

use std::fs::{DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use chacha20poly1305::{AeadInOut, KeyInit, Tag, XChaCha20Poly1305, XNonce};
use serde::de::{Deserializer, IgnoredAny, MapAccess, Visitor};
use serde_json::{Value, json};

/// The largest export the gateway takes (32 MiB). The body is held in memory once while it is
/// encrypted in place, and only one backup request runs at a time, so the service stays far
/// below its 128 MB `MemoryMax`.
pub const MAX_BACKUP_BYTES: usize = 32 * 1024 * 1024;
pub const KEPT: usize = 14;

const MAGIC: &[u8; 8] = b"MIOBAK01";
const NONCE_BYTES: usize = 24;
const TAG_BYTES: usize = 16;
const OVERHEAD: usize = MAGIC.len() + NONCE_BYTES + TAG_BYTES;
const EXTENSION: &str = ".mio-backup";
const KEY_FILE: &str = "backup.key";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupError {
    /// The disk, the key file or the random generator failed (507 `backup_storage_failed`).
    Storage,
    /// No copy with that id (404 `backup_not_found`).
    NotFound,
    /// The copy exists but cannot be decrypted: wrong key, damaged file or unknown format.
    Unreadable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: String,
    pub created_at: String,
    /// The size of the export itself, without the encryption's 48 bytes.
    pub bytes: u64,
}

impl Entry {
    pub fn to_json(&self) -> Value {
        json!({ "id": self.id, "createdAt": self.created_at, "bytes": self.bytes })
    }
}

/// Only the two fields the contract names are read; everything else is skipped without being
/// stored, so a 32 MB export is checked without building it as a JSON tree in memory.
struct Header {
    valid: bool,
}

impl<'de> serde::Deserialize<'de> for Header {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Fields;
        impl<'de> Visitor<'de> for Fields {
            type Value = Header;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("an export object")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Header, A::Error> {
                let (mut version, mut exported) = (None, None);
                while let Some(key) = map.next_key::<std::borrow::Cow<'de, str>>()? {
                    match key.as_ref() {
                        // A value of the wrong type is a syntax error here, and so a 400 as well.
                        "schemaVersion" if version.is_none() => version = Some(map.next_value::<serde_json::Number>()?),
                        "exportedAt" if exported.is_none() => exported = Some(map.next_value::<std::borrow::Cow<'de, str>>()?),
                        "schemaVersion" | "exportedAt" => return Err(serde::de::Error::custom("duplicate field")),
                        _ => {
                            map.next_value::<IgnoredAny>()?;
                        }
                    }
                }
                let version_ok = version.as_ref().and_then(serde_json::Number::as_u64) == Some(2);
                let exported_ok = exported.as_deref().is_some_and(|text| !crate::js::is_blank(text) && text.len() <= 100);
                Ok(Header { valid: version_ok && exported_ok })
            }
        }
        deserializer.deserialize_map(Fields)
    }
}

/// True for a JSON object with `schemaVersion` 2 and a non-empty string `exportedAt`.
pub fn is_valid_export(body: &[u8]) -> bool {
    serde_json::from_slice::<Header>(body).is_ok_and(|header| header.valid)
}

/// `ÅÅÅÅMMDDTHHMMSSZ-<8 hex>`, the only file names the store reads or deletes.
pub fn is_backup_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    bytes.len() == 25 && bytes.iter().enumerate().all(|(index, byte)| match index {
        8 => *byte == b'T',
        15 => *byte == b'Z',
        16 => *byte == b'-',
        0..8 | 9..15 => byte.is_ascii_digit(),
        _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
    })
}

fn created_at(id: &str) -> String {
    format!("{}-{}-{}T{}:{}:{}Z", &id[0..4], &id[4..6], &id[6..8], &id[9..11], &id[11..13], &id[13..15])
}

fn stamp(now_ms: i64) -> String {
    let seconds = now_ms.div_euclid(1_000);
    let (year, month, day) = crate::time::civil_from_days(seconds.div_euclid(86_400));
    let time = seconds.rem_euclid(86_400);
    format!("{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z", time / 3_600, time % 3_600 / 60, time % 60)
}

fn random<const N: usize>() -> Result<[u8; N], BackupError> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|_| BackupError::Storage)?;
    Ok(bytes)
}

/// The backups and their key in one state directory (`/var/lib/mio-gateway` under systemd).
pub struct BackupStore {
    directory: PathBuf,
}

impl BackupStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self { directory: directory.into() }
    }

    fn backups(&self) -> PathBuf {
        self.directory.join("backups")
    }

    fn key_path(&self) -> PathBuf {
        self.directory.join(KEY_FILE)
    }

    /// The existing key, never replaced: a key file of the wrong size stops every backup instead
    /// of orphaning the copies made with it.
    fn read_key(&self) -> Result<Option<[u8; 32]>, BackupError> {
        match std::fs::read(self.key_path()) {
            Ok(bytes) => bytes.try_into().map(Some).map_err(|_| BackupError::Storage),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err(BackupError::Storage),
        }
    }

    /// Creates the key on the first backup: 32 random bytes, 0600, written in full to a temporary
    /// file and linked into place, which fails rather than overwrite a key that appeared meanwhile.
    fn key(&self) -> Result<[u8; 32], BackupError> {
        if let Some(key) = self.read_key()? {
            return Ok(key);
        }
        let key = random::<32>()?;
        let temporary = self.directory.join(format!("{KEY_FILE}.{}.tmp", hex(&random::<4>()?)));
        let written = (|| {
            let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
            file.write_all(&key)?;
            file.sync_all()?;
            std::fs::hard_link(&temporary, self.key_path())
        })();
        let _ = std::fs::remove_file(&temporary);
        match written {
            Ok(()) => Ok(key),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => self.read_key()?.ok_or(BackupError::Storage),
            Err(_) => Err(BackupError::Storage),
        }
    }

    /// Encrypts and stores one export, then removes everything beyond the 14 newest copies.
    /// Returns the new copy and how many are kept.
    pub fn save(&self, mut export: Vec<u8>, now_ms: i64) -> Result<(Entry, usize), BackupError> {
        let cipher = XChaCha20Poly1305::new(&self.key()?.into());
        let backups = self.backups();
        DirBuilder::new().recursive(true).mode(0o700).create(&backups).map_err(|_| BackupError::Storage)?;
        let id = loop {
            let id = format!("{}-{}", stamp(now_ms), hex(&random::<4>()?));
            if !backups.join(format!("{id}{EXTENSION}")).exists() {
                break id;
            }
        };
        let nonce = random::<NONCE_BYTES>()?;
        let tag = cipher.encrypt_inout_detached(&XNonce::from(nonce), MAGIC, export.as_mut_slice().into())
            .map_err(|_| BackupError::Storage)?;
        let temporary = backups.join(format!(".{id}.tmp"));
        let final_path = backups.join(format!("{id}{EXTENSION}"));
        let written = (|| {
            let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
            file.write_all(MAGIC)?;
            file.write_all(&nonce)?;
            file.write_all(&export)?;
            file.write_all(tag.as_slice())?;
            file.sync_all()?;
            std::fs::rename(&temporary, &final_path)?;
            // The rename itself survives a power cut only once the directory is on disk.
            File::open(&backups)?.sync_all()
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
            if !final_path.exists() {
                return Err(BackupError::Storage);
            }
        }
        let entry = Entry { id: id.clone(), created_at: created_at(&id), bytes: export.len() as u64 };
        drop(export);
        let kept = self.prune(&id);
        Ok((entry, kept))
    }

    /// Deletes copies beyond the newest 14 and temporary files left by an interrupted write.
    /// Only names this module writes are touched. Returns the number of copies kept.
    ///
    /// Ids sort by the PC's clock at the time of writing. `just_written` is never deleted here, so
    /// a clock that once stood far ahead cannot make every new copy vanish right after its 201:
    /// the 13 newest others by id are kept beside it.
    fn prune(&self, just_written: &str) -> usize {
        let entries = self.list();
        let others = entries.iter().filter(|entry| entry.id != just_written);
        for old in others.skip(KEPT - 1) {
            let _ = std::fs::remove_file(self.backups().join(format!("{}{EXTENSION}", old.id)));
        }
        if let Ok(listing) = std::fs::read_dir(self.backups()) {
            for name in listing.flatten().filter_map(|entry| entry.file_name().into_string().ok()) {
                let stale = name.strip_prefix('.').and_then(|rest| rest.strip_suffix(".tmp")).is_some_and(is_backup_id);
                if stale {
                    let _ = std::fs::remove_file(self.backups().join(name));
                }
            }
        }
        entries.len().min(KEPT)
    }

    /// The stored copies, newest first. A missing directory means none.
    pub fn list(&self) -> Vec<Entry> {
        let Ok(listing) = std::fs::read_dir(self.backups()) else { return Vec::new() };
        let mut entries: Vec<Entry> = listing.flatten().filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let id = name.strip_suffix(EXTENSION).filter(|id| is_backup_id(id))?;
            let metadata = entry.metadata().ok().filter(std::fs::Metadata::is_file)?;
            Some(Entry { id: id.to_owned(), created_at: created_at(id),
                bytes: metadata.len().saturating_sub(OVERHEAD as u64) })
        }).collect();
        entries.sort_by(|left, right| right.id.cmp(&left.id));
        entries
    }

    /// The decrypted export of one copy.
    pub fn read(&self, id: &str) -> Result<Vec<u8>, BackupError> {
        if !is_backup_id(id) {
            return Err(BackupError::NotFound);
        }
        let path = self.backups().join(format!("{id}{EXTENSION}"));
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(BackupError::NotFound),
            Err(_) => return Err(BackupError::Storage),
        };
        let length = file.metadata().map_err(|_| BackupError::Storage)?.len();
        if length < OVERHEAD as u64 || length > (MAX_BACKUP_BYTES + OVERHEAD) as u64 {
            return Err(BackupError::Unreadable);
        }
        let mut data = Vec::with_capacity(length as usize);
        file.read_to_end(&mut data).map_err(|_| BackupError::Storage)?;
        if data.len() < OVERHEAD || !data.starts_with(MAGIC) {
            return Err(BackupError::Unreadable);
        }
        let key = self.read_key().map_err(|_| BackupError::Unreadable)?.ok_or(BackupError::Unreadable)?;
        let cipher = XChaCha20Poly1305::new(&key.into());
        let nonce = XNonce::try_from(&data[MAGIC.len()..MAGIC.len() + NONCE_BYTES]).map_err(|_| BackupError::Unreadable)?;
        let tag = Tag::try_from(&data[data.len() - TAG_BYTES..]).map_err(|_| BackupError::Unreadable)?;
        let end = data.len() - TAG_BYTES;
        cipher.decrypt_inout_detached(&nonce, MAGIC, data[MAGIC.len() + NONCE_BYTES..end].as_mut().into(), &tag)
            .map_err(|_| BackupError::Unreadable)?;
        data.truncate(end);
        data.drain(..MAGIC.len() + NONCE_BYTES);
        Ok(data)
    }

    /// The `backup` object of `/v2/status`.
    pub fn summary(&self) -> Value {
        summary(&self.list())
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }
}

pub fn summary(entries: &[Entry]) -> Value {
    json!({ "latestAt": entries.first().map(|entry| entry.created_at.clone()),
        "count": entries.len(), "bytes": entries.iter().map(|entry| entry.bytes).sum::<u64>() })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
