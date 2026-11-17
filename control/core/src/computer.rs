//! Datorn: the panel's own preferences, the login entry and keeping the computer awake.

use std::path::{Path, PathBuf};

use zbus::blocking::Connection;

/// The login entry `control/install.sh` installs, kept identical so the toggle can restore it.
pub const AUTOSTART_ENTRY: &str = include_str!("../../desktop/app.mio.control-autostart.desktop");

/// `$XDG_CONFIG_HOME`, or `~/.config`.
pub fn config_home() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
}

pub fn autostart_path() -> Option<PathBuf> {
    Some(config_home()?.join("autostart/app.mio.control.desktop"))
}

pub fn preferences_path() -> Option<PathBuf> {
    Some(config_home()?.join("mio-control/installningar"))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Preferences {
    /// Hold a KDE power inhibition for as long as the panel runs.
    pub keep_awake: bool,
    /// Show the tray icon. Without it the window opens at start and closing it quits the panel.
    pub tray: bool,
}

impl Default for Preferences {
    fn default() -> Self {
        Self { keep_awake: false, tray: true }
    }
}

impl Preferences {
    /// `håll-vaken=ja|nej` and `systemfält=ja|nej`, one per line; anything else keeps the default.
    pub fn parse(text: &str) -> Self {
        let mut preferences = Self::default();
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else { continue };
            let on = match value.trim() {
                "ja" => true,
                "nej" => false,
                _ => continue,
            };
            match key.trim() {
                "håll-vaken" => preferences.keep_awake = on,
                "systemfält" => preferences.tray = on,
                _ => {}
            }
        }
        preferences
    }

    pub fn to_text(self) -> String {
        let word = |on: bool| if on { "ja" } else { "nej" };
        format!("håll-vaken={}\nsystemfält={}\n", word(self.keep_awake), word(self.tray))
    }

    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path).map(|text| Self::parse(&text)).unwrap_or_default()
    }

    pub fn save(self, path: &Path) -> Result<(), String> {
        let fail = |_| "Kunde inte spara panelens inställningar.".to_owned();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(fail)?;
        }
        std::fs::write(path, self.to_text()).map_err(fail)
    }
}

/// Writes or removes the login entry.
pub fn set_autostart(path: &Path, on: bool) -> Result<(), String> {
    let result = if on {
        path.parent().map_or(Ok(()), std::fs::create_dir_all).and_then(|()| std::fs::write(path, AUTOSTART_ENTRY))
    } else {
        match std::fs::remove_file(path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    };
    result.map_err(|_| "Kunde inte ändra start vid inloggning.".to_owned())
}

const POWER: &str = "org.freedesktop.PowerManagement";
const INHIBIT_PATH: &str = "/org/freedesktop/PowerManagement/Inhibit";
const INHIBIT: &str = "org.freedesktop.PowerManagement.Inhibit";

/// A held inhibition of sleep. KDE's power management (PowerDevil) keeps it until it is released
/// or the connection closes, so a crashed panel never keeps the computer awake.
pub struct Inhibition {
    connection: Connection,
    cookie: u32,
}

pub fn inhibit() -> Result<Inhibition, String> {
    let unavailable = |_| "Skrivbordet tar inte emot begäran om att hålla datorn vaken (org.freedesktop.PowerManagement saknas).".to_owned();
    let connection = Connection::session().map_err(unavailable)?;
    let reply = connection
        .call_method(Some(POWER), INHIBIT_PATH, Some(INHIBIT), "Inhibit", &("Mio Kontroll", "Mio transkriberar och svarar telefonen"))
        .map_err(unavailable)?;
    let cookie = reply.body().deserialize::<u32>().map_err(unavailable)?;
    Ok(Inhibition { connection, cookie })
}

impl Drop for Inhibition {
    fn drop(&mut self) {
        let _ = self.connection.call_method(Some(POWER), INHIBIT_PATH, Some(INHIBIT), "UnInhibit", &(self.cookie,));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferences_round_trip_and_tolerate_noise() {
        assert_eq!(Preferences::parse(""), Preferences { keep_awake: false, tray: true });
        let preferences = Preferences { keep_awake: true, tray: false };
        assert_eq!(Preferences::parse(&preferences.to_text()), preferences);
        assert_eq!(Preferences::parse("håll-vaken=kanske\nannat=ja\nsystemfält = nej\n"), Preferences { keep_awake: false, tray: false });
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("mio-control/installningar");
        preferences.save(&path).unwrap();
        assert_eq!(Preferences::load(&path), preferences);
    }

    #[test]
    fn the_login_entry_is_written_and_removed() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("autostart/app.mio.control.desktop");
        set_autostart(&path, true).unwrap();
        assert!(std::fs::read_to_string(&path).unwrap().contains("Exec=/usr/local/bin/mio-control\n"));
        set_autostart(&path, false).unwrap();
        assert!(!path.exists());
        set_autostart(&path, false).unwrap();
    }
}
