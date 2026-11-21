//! The nightly backup's receiver (contract "Säkerhetskopian" in docs/DATAMODELL.md), with
//! synthetic exports only and a scratch directory per test.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use common::{Provider, Server, Upstream, authorized, start};
use mio_gateway::backup::{BackupError, BackupStore, KEPT, MAX_BACKUP_BYTES, is_backup_id, is_valid_export};
use mio_gateway::server::Gateway;
use serde_json::{Value, json};

const NOVEMBER: i64 = 1_795_176_000_000; // 2026-11-20T12:00:00Z

fn scratch(name: &str) -> PathBuf {
    let directory = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("backup-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

fn export(marker: &str) -> Vec<u8> {
    json!({ "schemaVersion": 2, "exportedAt": "2026-11-20T03:00:00Z",
        "sessions": [{ "text": format!("Syntetisk lektion {marker}"), "nested": { "list": [1, 2.5, null, true] } }] })
        .to_string().into_bytes()
}

#[test]
fn only_an_object_with_schema_version_2_and_exported_at_is_accepted() {
    assert!(is_valid_export(&export("a")));
    assert!(is_valid_export(br#"{"exportedAt":"2026-11-20T03:00:00Z","schemaVersion":2,"x":{"y":[1,{"z":"\u00e5"}]}}"#));
    for body in [&br#"{"schemaVersion":1,"exportedAt":"2026-11-20T03:00:00Z"}"#[..], br#"{"schemaVersion":"2","exportedAt":"x"}"#,
        br#"{"schemaVersion":2}"#, br#"{"exportedAt":"x"}"#, br#"{"schemaVersion":2,"exportedAt":""}"#,
        br#"{"schemaVersion":2,"exportedAt":7}"#, br#"{"schemaVersion":2,"exportedAt":"x","schemaVersion":2}"#,
        br#"[{"schemaVersion":2,"exportedAt":"x"}]"#, br#"{"schemaVersion":2,"exportedAt":"x"} trailing"#,
        br#"{"schemaVersion":2,"exportedAt":"x","broken":"#, b"", b"\xff"] {
        assert!(!is_valid_export(body), "{}", String::from_utf8_lossy(body));
    }
}

#[test]
fn a_copy_is_encrypted_on_disk_and_decrypts_to_the_same_bytes() {
    let directory = scratch("roundtrip");
    let store = BackupStore::new(&directory);
    let plain = export("hemlig-markör");
    let (entry, kept) = store.save(plain.clone(), NOVEMBER).unwrap();
    assert!(is_backup_id(&entry.id) && entry.id.starts_with("20261120T120000Z-"), "{}", entry.id);
    assert_eq!((entry.created_at.as_str(), entry.bytes, kept), ("2026-11-20T12:00:00Z", plain.len() as u64, 1));
    let key = directory.join("backup.key");
    assert_eq!(std::fs::read(&key).unwrap().len(), 32);
    assert_eq!(std::fs::metadata(&key).unwrap().permissions().mode() & 0o777, 0o600);
    let file = directory.join("backups").join(format!("{}.mio-backup", entry.id));
    let stored = std::fs::read(&file).unwrap();
    assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(stored.len(), plain.len() + 48);
    assert!(!stored.windows(5).any(|window| window == b"hemli"), "the export never lies on disk in clear text");
    assert_eq!(store.read(&entry.id).unwrap(), plain);
    assert_eq!(store.list(), vec![entry.clone()]);
    // The key is created once and kept.
    let first_key = std::fs::read(&key).unwrap();
    let (second, _) = store.save(export("b"), NOVEMBER + 1_000).unwrap();
    assert_eq!(std::fs::read(&key).unwrap(), first_key);
    assert_eq!(store.list().first().unwrap().id, second.id, "newest first");
    assert!(std::fs::read_dir(directory.join("backups")).unwrap().all(|entry| !entry.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
}

#[test]
fn only_the_14_newest_copies_are_kept() {
    let directory = scratch("fourteen");
    let store = BackupStore::new(&directory);
    let mut ids = Vec::new();
    for night in 0..20 {
        let (entry, kept) = store.save(export(&night.to_string()), NOVEMBER + night * 86_400_000).unwrap();
        assert_eq!(kept, (night as usize + 1).min(KEPT));
        ids.push(entry.id);
    }
    let listed: Vec<String> = store.list().into_iter().map(|entry| entry.id).collect();
    let mut newest: Vec<String> = ids[ids.len() - KEPT..].to_vec();
    newest.reverse();
    assert_eq!(listed, newest);
    assert_eq!(store.read(&ids[0]), Err(BackupError::NotFound));
    assert_eq!(store.read(ids.last().unwrap()).unwrap(), export("19"));
    // A file the store did not write is never touched.
    std::fs::write(directory.join("backups").join("anteckning.txt"), b"egen fil").unwrap();
    store.save(export("x"), NOVEMBER + 30 * 86_400_000).unwrap();
    assert!(directory.join("backups").join("anteckning.txt").exists());
    assert_eq!(store.list().len(), KEPT);
}

#[test]
fn a_wrong_key_or_a_damaged_file_is_unreadable_and_never_overwritten() {
    let directory = scratch("damaged");
    let store = BackupStore::new(&directory);
    let (entry, _) = store.save(export("a"), NOVEMBER).unwrap();
    let file = directory.join("backups").join(format!("{}.mio-backup", entry.id));
    let original = std::fs::read(&file).unwrap();
    let mut flipped = original.clone();
    let middle = flipped.len() / 2;
    flipped[middle] ^= 1;
    std::fs::write(&file, &flipped).unwrap();
    assert_eq!(store.read(&entry.id), Err(BackupError::Unreadable));
    std::fs::write(&file, &original[..20]).unwrap();
    assert_eq!(store.read(&entry.id), Err(BackupError::Unreadable));
    std::fs::write(&file, &original).unwrap();
    assert!(store.read(&entry.id).is_ok());
    let key = directory.join("backup.key");
    std::fs::write(&key, [7u8; 32]).unwrap();
    assert_eq!(store.read(&entry.id), Err(BackupError::Unreadable));
    // A key file of the wrong size stops new copies instead of being replaced.
    std::fs::write(&key, [7u8; 31]).unwrap();
    assert_eq!(store.save(export("b"), NOVEMBER + 1_000), Err(BackupError::Storage));
    assert_eq!(std::fs::read(&key).unwrap(), vec![7u8; 31]);
    for id in ["../backup.key", "20261120T120000Z-ABCDEF12", "x"] {
        assert_eq!(store.read(id), Err(BackupError::NotFound));
    }
}

#[test]
fn a_directory_that_cannot_be_written_is_a_storage_failure() {
    let directory = scratch("readonly");
    std::fs::write(directory.join("backups"), b"a file where the directory should be").unwrap();
    let store = BackupStore::new(&directory);
    assert_eq!(store.save(export("a"), NOVEMBER), Err(BackupError::Storage));
    assert!(store.list().is_empty());
}

struct Fixture {
    server: Server,
    provider: Arc<Provider>,
    clock: Arc<AtomicI64>,
    directory: PathBuf,
}

async fn fixture(name: &str) -> Fixture {
    let directory = scratch(name);
    let provider = Provider::fixed(Upstream::Fail);
    let clock = Arc::new(AtomicI64::new(NOVEMBER));
    let time = clock.clone();
    let gateway = Gateway::new(common::config(), Arc::new(common::Link(provider.clone()))).unwrap()
        .with_clock(move || time.load(Ordering::SeqCst)).with_backup_store(Arc::new(BackupStore::new(&directory)));
    Fixture { server: start(gateway).await, provider, clock, directory }
}

async fn put(server: &Server, body: &[u8]) -> common::Reply {
    server.request("PUT", "/v2/backup", &authorized(), Some(body)).await
}

#[tokio::test]
async fn the_routes_store_list_and_return_copies_outside_the_ai_quota() {
    let Fixture { server, provider, clock, directory } = fixture("routes").await;
    let before = server.status_v2().await;
    assert_eq!(before["backup"], json!({ "latestAt": null, "count": 0, "bytes": 0 }));
    let quota = before["quota"]["remaining"].clone();
    let created = put(&server, &export("a")).await;
    assert_eq!(created.status, 201, "{}", created.body);
    let body = created.json();
    assert_eq!(body["createdAt"], "2026-11-20T12:00:00Z");
    assert_eq!((body["bytes"].as_u64(), body["kept"].as_u64()), (Some(export("a").len() as u64), Some(1)));
    clock.fetch_add(86_400_000, Ordering::SeqCst);
    let second = put(&server, &export("bb")).await.json();
    let listed = server.get("/v2/backups", &authorized()).await;
    assert_eq!(listed.status, 200);
    let backups = listed.json()["backups"].as_array().unwrap().clone();
    assert_eq!(backups.len(), 2);
    assert_eq!(backups[0], json!({ "id": second["id"], "createdAt": "2026-11-21T12:00:00Z", "bytes": export("bb").len() }));
    let restored = server.get(&format!("/v2/backups/{}", body["id"].as_str().unwrap()), &authorized()).await;
    assert_eq!(restored.status, 200);
    assert_eq!(restored.header("content-type"), Some("application/json"));
    assert_eq!(restored.body.as_bytes(), export("a"));
    let missing = server.get("/v2/backups/20261120T120000Z-00000000", &authorized()).await;
    assert_eq!((missing.status, missing.error().as_str()), (404, "backup_not_found"));
    let status = server.status_v2().await;
    assert_eq!(status["backup"], json!({ "latestAt": "2026-11-21T12:00:00Z", "count": 2,
        "bytes": export("a").len() + export("bb").len() }));
    assert_eq!(status["quota"]["remaining"], quota, "backups never count against the AI quota");
    assert_eq!(provider.count(), 0, "nothing reaches a provider");
    assert!(directory.join("backup.key").exists());
}

#[tokio::test]
async fn refusals_follow_the_contract() {
    let Fixture { server, directory, .. } = fixture("refusals").await;
    let unauthorized = server.request("PUT", "/v2/backup", &[("Content-Type", "application/json".to_owned())], Some(&export("a"))).await;
    assert_eq!(unauthorized.status, 401);
    assert_eq!(server.get("/v2/backups", &[]).await.status, 401);
    assert_eq!(server.get("/v2/backups/20261120T120000Z-00000000", &[]).await.status, 401);
    for body in [&br#"{"schemaVersion":1,"exportedAt":"x"}"#[..], b"not json", br#"{"schemaVersion":2}"#] {
        let refused = put(&server, body).await;
        assert_eq!((refused.status, refused.error().as_str()), (400, "invalid_backup"));
    }
    let text = server.request("PUT", "/v2/backup", &[("Authorization", format!("Bearer {}", common::TOKEN)),
        ("Content-Type", "text/plain".to_owned())], Some(&export("a"))).await;
    assert_eq!(text.status, 415);
    // Declared too large: refused before any body is read.
    let mut headers = authorized();
    headers.push(("Content-Length", (MAX_BACKUP_BYTES + 1).to_string()));
    let large = server.request("PUT", "/v2/backup", &headers, None).await;
    assert_eq!((large.status, large.error().as_str()), (413, "request_too_large"));
    assert_eq!(server.request("POST", "/v2/backup", &authorized(), Some(&export("a"))).await.status, 404);
    assert!(!directory.join("backups").exists(), "nothing was stored");
    assert!(!directory.join("backup.key").exists(), "the key is made with the first copy");
}

#[tokio::test]
async fn an_export_just_under_the_limit_is_stored_and_one_over_is_refused() {
    let Fixture { server, .. } = fixture("limit").await;
    let prefix = br#"{"schemaVersion":2,"exportedAt":"2026-11-20T03:00:00Z","fill":""#;
    let mut body = prefix.to_vec();
    body.resize(MAX_BACKUP_BYTES - 2, b'a');
    body.extend_from_slice(b"\"}");
    assert_eq!(body.len(), MAX_BACKUP_BYTES);
    let stored = put(&server, &body).await;
    assert_eq!(stored.status, 201, "{}", stored.body);
    body.insert(prefix.len(), b'a');
    let refused = put(&server, &body).await;
    assert_eq!(refused.status, 413);
}

#[tokio::test]
async fn a_gateway_without_a_backup_directory_reports_none_and_refuses_with_507() {
    let provider = Provider::fixed(Upstream::Fail);
    let server = common::serve(common::config(), &provider).await;
    assert_eq!(server.status_v2().await["backup"], json!({ "latestAt": null, "count": 0, "bytes": 0 }));
    let refused = put(&server, &export("a")).await;
    assert_eq!((refused.status, refused.error().as_str()), (507, "backup_storage_failed"));
    assert_eq!(server.get("/v2/backups", &authorized()).await.json(), json!({ "backups": [] }));
}

#[tokio::test]
async fn a_damaged_copy_answers_500_without_details() {
    let Fixture { server, directory, .. } = fixture("damaged-route").await;
    let id = put(&server, &export("a")).await.json()["id"].as_str().unwrap().to_owned();
    let file = directory.join("backups").join(format!("{id}.mio-backup"));
    let mut data = std::fs::read(&file).unwrap();
    let last = data.len() - 1;
    data[last] ^= 0xff;
    std::fs::write(&file, data).unwrap();
    let reply = server.get(&format!("/v2/backups/{id}"), &authorized()).await;
    assert_eq!(reply.json(), json!({ "error": "backup_unreadable" }));
    assert_eq!(reply.status, 500);
    let _: Value = reply.json();
}
