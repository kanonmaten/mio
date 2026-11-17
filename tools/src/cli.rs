//! A small argparse-like parser: flags, `--option value` and `--option=value`, `-h`.

use std::collections::HashMap;

pub struct Spec {
    pub command: &'static str,
    pub about: &'static str,
    /// Flags without a value, with help text.
    pub flags: &'static [(&'static str, &'static str)],
    /// Options that take one value, with help text.
    pub options: &'static [(&'static str, &'static str)],
}

pub struct Parsed {
    flags: Vec<&'static str>,
    options: HashMap<&'static str, String>,
}

impl Spec {
    fn usage(&self) -> String {
        let mut usage = format!("usage: mio-verify {} [-h]", self.command);
        for (flag, _) in self.flags {
            usage.push_str(&format!(" [{flag}]"));
        }
        for (option, _) in self.options {
            let value = option.trim_start_matches('-').replace('-', "_").to_uppercase();
            usage.push_str(&format!(" [{option} {value}]"));
        }
        usage
    }

    fn help(&self) -> String {
        let mut help = format!("{}\n\n{}\n\noptions:\n  -h, --help  show this help message and exit\n", self.usage(), self.about);
        for (name, text) in self.flags.iter().chain(self.options) {
            help.push_str(&format!("  {name}  {text}\n"));
        }
        help
    }

    /// Prints usage and an error to stderr; argparse exits with 2.
    pub fn error(&self, message: &str) -> u8 {
        eprintln!("{}\nmio-verify {}: error: {message}", self.usage(), self.command);
        2
    }
}

impl Parsed {
    /// Returns the exit code to stop with on `-h` (0) or an argument error (2).
    pub fn parse(spec: &Spec, arguments: &[String]) -> Result<Parsed, u8> {
        let mut parsed = Parsed { flags: Vec::new(), options: HashMap::new() };
        let mut index = 0;
        while index < arguments.len() {
            let argument = arguments[index].as_str();
            index += 1;
            if argument == "-h" || argument == "--help" {
                print!("{}", spec.help());
                return Err(0);
            }
            let (name, inline) = match argument.split_once('=') {
                Some((name, value)) if name.starts_with("--") => (name, Some(value.to_owned())),
                _ => (argument, None),
            };
            if let Some((flag, _)) = spec.flags.iter().find(|(flag, _)| *flag == name) {
                if inline.is_some() {
                    return Err(spec.error(&format!("argument {flag}: ignored explicit argument '{}'", inline.unwrap_or_default())));
                }
                parsed.flags.push(flag);
            } else if let Some((option, _)) = spec.options.iter().find(|(option, _)| *option == name) {
                let value = match inline {
                    Some(value) => value,
                    None if index < arguments.len() && !arguments[index].starts_with('-') => {
                        index += 1;
                        arguments[index - 1].clone()
                    }
                    None => return Err(spec.error(&format!("argument {option}: expected one argument"))),
                };
                parsed.options.insert(option, value);
            } else {
                return Err(spec.error(&format!("unrecognized arguments: {}", arguments[index - 1..].join(" "))));
            }
        }
        Ok(parsed)
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }

    pub fn option(&self, name: &str) -> Option<&str> {
        self.options.get(name).map(String::as_str)
    }
}
