//! Environment files (`gateway.env`, `mio-transcription.conf`) edited in place.
//!
//! Only the lines that change are rewritten: comments, blank lines, order, unknown variables and
//! bytes that are not UTF-8 (a Latin-1 comment) stay exactly as they were. Values are read the
//! way systemd's `EnvironmentFile=` reads them, which is how both services get them.

/// A key systemd and Mio accept: upper-case ASCII, digits and underscores, not starting with a digit.
pub fn is_valid_key(key: &str) -> bool {
    let mut characters = key.chars();
    characters.next().is_some_and(|first| first.is_ascii_uppercase() || first == '_')
        && characters.all(|character| character.is_ascii_uppercase() || character.is_ascii_digit() || character == '_')
}

/// A value that fits on one unquoted line and reads back unchanged.
pub fn is_valid_value(value: &str) -> bool {
    value.len() <= 4096
        && !value.chars().any(|character| character.is_control())
        && value.trim() == value
        && !(value.len() >= 2 && ['"', '\''].iter().any(|quote| value.starts_with(*quote) && value.ends_with(*quote)))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvFile {
    lines: Vec<Vec<u8>>,
    /// Whether the file ended with a line break; kept as it was.
    trailing_newline: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvError {
    InvalidKey,
    InvalidValue,
}

impl std::fmt::Display for EnvError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            EnvError::InvalidKey => "Ogiltigt namn på inställning.",
            EnvError::InvalidValue => "Värdet får inte innehålla radbrytningar, styrtecken eller citattecken runt sig.",
        })
    }
}

impl std::error::Error for EnvError {}

/// The key and value of an assignment line, or `None` for comments, blanks and other text.
fn assignment(line: &[u8]) -> Option<(String, String)> {
    let text = std::str::from_utf8(line.strip_suffix(b"\r").unwrap_or(line)).ok()?.trim();
    if text.is_empty() || text.starts_with('#') || text.starts_with(';') {
        return None;
    }
    let (key, value) = text.split_once('=')?;
    let value = value.trim();
    let unquoted = ['"', '\'']
        .iter()
        .find_map(|quote| value.strip_prefix(*quote)?.strip_suffix(*quote).filter(|_| value.len() >= 2));
    Some((key.trim().to_owned(), unquoted.unwrap_or(value).to_owned()))
}

impl EnvFile {
    pub fn parse(bytes: &[u8]) -> Self {
        let trailing_newline = bytes.ends_with(b"\n");
        let body = bytes.strip_suffix(b"\n").unwrap_or(bytes);
        let lines = if bytes.is_empty() { Vec::new() } else { body.split(|byte| *byte == b'\n').map(<[u8]>::to_vec).collect() };
        Self { lines, trailing_newline: trailing_newline || bytes.is_empty() }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = self.lines.join(&b'\n');
        if self.trailing_newline && !self.lines.is_empty() {
            bytes.push(b'\n');
        }
        bytes
    }

    /// The value systemd would pass on: the last assignment wins.
    pub fn get(&self, key: &str) -> Option<String> {
        self.lines
            .iter()
            .rev()
            .filter_map(|line| assignment(line))
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    /// Every assigned key once, in file order.
    pub fn keys(&self) -> Vec<String> {
        let mut keys: Vec<String> = Vec::new();
        for (key, _) in self.lines.iter().filter_map(|line| assignment(line)) {
            if !keys.contains(&key) {
                keys.push(key);
            }
        }
        keys
    }

    /// Sets `key` on the line where it was last assigned and drops earlier duplicates; a new key
    /// goes last. Every other line is kept byte for byte.
    pub fn set(&mut self, key: &str, value: &str) -> Result<(), EnvError> {
        if !is_valid_key(key) {
            return Err(EnvError::InvalidKey);
        }
        if !is_valid_value(value) {
            return Err(EnvError::InvalidValue);
        }
        let positions: Vec<usize> = self.positions(key);
        let line = format!("{key}={value}").into_bytes();
        match positions.split_last() {
            Some((last, earlier)) => {
                self.lines[*last] = line;
                for index in earlier.iter().rev() {
                    self.lines.remove(*index);
                }
            }
            None => self.lines.push(line),
        }
        Ok(())
    }

    /// Removes every assignment of `key`; returns whether there was one.
    pub fn remove(&mut self, key: &str) -> bool {
        let positions = self.positions(key);
        for index in positions.iter().rev() {
            self.lines.remove(*index);
        }
        !positions.is_empty()
    }

    fn positions(&self, key: &str) -> Vec<usize> {
        self.lines
            .iter()
            .enumerate()
            .filter(|(_, line)| assignment(line).is_some_and(|(name, _)| name == key))
            .map(|(index, _)| index)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GATEWAY: &[u8] = b"# Mio gateway. Dela aldrig denna fil.\nGROQ_API_KEY=gsk_old\nMIO_GATEWAY_TOKEN=abc\n\n# egen \xe5\xe4\xf6 i Latin-1\nMIO_REQUESTS_PER_MINUTE=10\nOKAND_RAD utan likhetstecken\nEGEN_VARIABEL=\"citerad\"\nPORT=8787\n";

    #[test]
    fn unchanged_file_is_written_back_byte_for_byte() {
        assert_eq!(EnvFile::parse(GATEWAY).to_bytes(), GATEWAY);
        let without_newline = b"A=1\nB=2";
        assert_eq!(EnvFile::parse(without_newline).to_bytes(), without_newline);
        assert_eq!(EnvFile::parse(b"").to_bytes(), b"");
    }

    #[test]
    fn comments_unknown_lines_and_latin1_survive_a_change() {
        let mut file = EnvFile::parse(GATEWAY);
        file.set("MIO_REQUESTS_PER_MINUTE", "20").unwrap();
        file.set("MIO_TOKENS_PER_DAY", "150000").unwrap();
        let expected: &[u8] = b"# Mio gateway. Dela aldrig denna fil.\nGROQ_API_KEY=gsk_old\nMIO_GATEWAY_TOKEN=abc\n\n# egen \xe5\xe4\xf6 i Latin-1\nMIO_REQUESTS_PER_MINUTE=20\nOKAND_RAD utan likhetstecken\nEGEN_VARIABEL=\"citerad\"\nPORT=8787\nMIO_TOKENS_PER_DAY=150000\n";
        assert_eq!(file.to_bytes(), expected);
    }

    #[test]
    fn values_read_like_systemd() {
        let file = EnvFile::parse(b"A=1\r\n B = tv\xc3\xa5 \nC=\"citerad\"\nD='enkel'\n#A=kommentar\nA=sist\n");
        assert_eq!(file.get("A").as_deref(), Some("sist"));
        assert_eq!(file.get("B").as_deref(), Some("två"));
        assert_eq!(file.get("C").as_deref(), Some("citerad"));
        assert_eq!(file.get("D").as_deref(), Some("enkel"));
        assert_eq!(file.get("E"), None);
        assert_eq!(file.keys(), ["A", "B", "C", "D"]);
    }

    #[test]
    fn duplicates_collapse_into_the_last_position() {
        let mut file = EnvFile::parse(b"A=1\nB=2\nA=3\nC=4\n");
        file.set("A", "5").unwrap();
        assert_eq!(file.to_bytes(), b"B=2\nA=5\nC=4\n");
        assert!(file.remove("B"));
        assert!(!file.remove("B"));
        assert_eq!(file.to_bytes(), b"A=5\nC=4\n");
    }

    #[test]
    fn unsafe_keys_and_values_are_refused() {
        let mut file = EnvFile::parse(b"A=1\n");
        for key in ["", "a", "1A", "A-B", "A B", "A=B"] {
            assert_eq!(file.set(key, "x"), Err(EnvError::InvalidKey), "{key}");
        }
        for value in ["rad\nbrytning", "vagn\rretur", " kant", "\"citerad\"", "nul\0"] {
            assert_eq!(file.set("A", value), Err(EnvError::InvalidValue), "{value:?}");
        }
        assert_eq!(file.to_bytes(), b"A=1\n");
        file.set("A", "").unwrap();
        assert_eq!(file.get("A").as_deref(), Some(""));
    }
}
