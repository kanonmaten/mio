//! Who listens on a loopback port, from the kernel's socket tables.
//!
//! The root helper sends a service's token to `127.0.0.1:<port>`. If the service is stopped,
//! another program running as the user could listen there and catch the token through the
//! password-free status command. So the token is only sent when every listener on the port
//! belongs to the service's own account (`mio-gateway`, `mio-transcription`).

/// Every listening socket's owner on `port` in one `/proc/net/tcp` or `/proc/net/tcp6` table.
pub fn listener_uids(table: &str, port: u16) -> Vec<u32> {
    let wanted = format!("{port:04X}");
    table
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            // sl, local_address, rem_address, st, tx:rx, tr:when, retrnsmt, uid, …
            let (local, state, uid) = (fields.get(1)?, fields.get(3)?, fields.get(7)?);
            let (_, local_port) = local.rsplit_once(':')?;
            (*state == "0A" && local_port.eq_ignore_ascii_case(&wanted)).then(|| uid.parse::<u32>().ok()).flatten()
        })
        .collect()
}

/// The numeric id of `user` from an `/etc/passwd` text.
pub fn passwd_uid(passwd: &str, user: &str) -> Option<u32> {
    passwd.lines().find_map(|line| {
        let mut fields = line.split(':');
        (fields.next()? == user).then(|| fields.nth(1)?.parse::<u32>().ok()).flatten()
    })
}

/// Whether `port` is listened on, and only by `user`, on this computer.
pub fn port_owned_by(port: u16, user: &str) -> bool {
    let Some(uid) = std::fs::read_to_string("/etc/passwd").ok().and_then(|passwd| passwd_uid(&passwd, user)) else {
        return false;
    };
    let owners: Vec<u32> = ["/proc/net/tcp", "/proc/net/tcp6"]
        .iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .flat_map(|table| listener_uids(&table, port))
        .collect();
    !owners.is_empty() && owners.iter().all(|owner| *owner == uid)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:223D 00000000:0000 0A 00000000:00000000 00:00000000 00000000   961        0 7497 1 0 100 0 0 10 0
   1: 0100007F:223D 0100007F:B1C2 01 00000000:00000000 00:00000000 00000000  1000        0 7498 1 0 100 0 0 10 0
   2: 00000000:223D 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 7499 1 0 100 0 0 10 0
";

    #[test]
    fn listeners_are_read_per_port_and_connections_ignored() {
        // 0x223D = 8765. The established connection (state 01) is not a listener.
        assert_eq!(listener_uids(TABLE, 8_765), [961, 1000]);
        assert_eq!(listener_uids(TABLE, 8_787), Vec::<u32>::new());
    }

    #[test]
    fn users_come_from_passwd() {
        let passwd = "root:x:0:0::/root:/bin/bash\nmio-transcription:x:961:961::/var/lib/mio-transcription:/usr/bin/nologin\n";
        assert_eq!(passwd_uid(passwd, "mio-transcription"), Some(961));
        assert_eq!(passwd_uid(passwd, "mio-gateway"), None);
    }

    #[test]
    fn an_unknown_account_never_owns_a_port() {
        assert!(!port_owned_by(1, "no-such-account-for-mio"));
    }

    #[test]
    fn a_real_listener_belongs_to_whoever_bound_it() {
        let status = std::fs::read_to_string("/proc/self/status").unwrap();
        let uid: u32 = status.lines().find(|line| line.starts_with("Uid:")).unwrap().split_whitespace().nth(1).unwrap().parse().unwrap();
        let passwd = std::fs::read_to_string("/etc/passwd").unwrap();
        let Some(me) = passwd.lines().find(|line| line.split(':').nth(2) == Some(uid.to_string().as_str())).map(|line| line.split(':').next().unwrap().to_owned()) else {
            return; // A container user without a passwd entry: nothing to compare against.
        };
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(port_owned_by(port, &me));
        assert!(!port_owned_by(port, if me == "root" { "nobody" } else { "root" }));
        // After the drop, another test or program may bind the same free port at once, so
        // "nobody listens on the port" is not something this test can assert. What it can
        // assert is that this listener's own socket (by inode) is gone from the tables.
        let inode = socket_inode(&listener);
        assert!(listening_inodes(port).contains(&inode));
        drop(listener);
        assert!(!listening_inodes(port).contains(&inode), "our listener is gone");
    }

    /// The kernel's inode for a socket, from `/proc/self/fd/<fd>` → `socket:[<inode>]`.
    fn socket_inode(listener: &std::net::TcpListener) -> String {
        use std::os::fd::AsRawFd;
        let link = std::fs::read_link(format!("/proc/self/fd/{}", listener.as_raw_fd())).unwrap();
        let link = link.to_string_lossy();
        link.strip_prefix("socket:[").and_then(|rest| rest.strip_suffix(']')).unwrap().to_owned()
    }

    /// The inodes of every listening socket on `port` in `/proc/net/tcp` and `/proc/net/tcp6`.
    fn listening_inodes(port: u16) -> Vec<String> {
        let wanted = format!("{port:04X}");
        ["/proc/net/tcp", "/proc/net/tcp6"]
            .iter()
            .filter_map(|path| std::fs::read_to_string(path).ok())
            .flat_map(|table| {
                table
                    .lines()
                    .skip(1)
                    .filter_map(|line| {
                        let fields: Vec<&str> = line.split_whitespace().collect();
                        let (local, state, inode) = (fields.get(1)?, fields.get(3)?, fields.get(9)?);
                        let (_, local_port) = local.rsplit_once(':')?;
                        (*state == "0A" && local_port.eq_ignore_ascii_case(&wanted)).then(|| (*inode).to_owned())
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }
}
