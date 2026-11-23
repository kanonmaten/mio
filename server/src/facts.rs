//! Whether a short text says what its quote says, as far as rules can tell (user decision
//! 2026-11-23, MIO-46). The quote is already proved to be in the transcript (`exact_quote`); this
//! checks the hard facts in the text beside it: every number, weekday, month and name in the text
//! must also be in the quote. An exam hint "Provet är på fredag" with the quote "provet är på
//! torsdag" fails, so the hint is dropped instead of teaching the wrong day.
//!
//! Only facts are checked, never meaning: "ska inte" turned into "ska" passes. A paraphrased
//! number ("hälften" for "50 procent") fails, which drops a true hint now and then but never
//! passes a wrong number. Spoken numbers in the quote count ("tjugo" is 20, "två tusen" is 2000,
//! "två komma fem" is 2.5, "tredje" is 3), since the transcript writes what was said. A number is
//! always compared whole: 5,2 never matches a quote that says 2,5.

/// Number words that add their value: 0 to 19.
const UNITS: [(&str, u64); 21] = [
    ("noll", 0), ("ett", 1), ("en", 1), ("två", 2), ("tre", 3), ("fyra", 4), ("fem", 5), ("sex", 6), ("sju", 7), ("åtta", 8),
    ("nio", 9), ("tio", 10), ("elva", 11), ("tolv", 12), ("tretton", 13), ("fjorton", 14), ("femton", 15), ("sexton", 16),
    ("sjutton", 17), ("arton", 18), ("nitton", 19),
];
const TENS: [(&str, u64); 8] = [
    ("tjugo", 20), ("trettio", 30), ("fyrtio", 40), ("femtio", 50), ("sextio", 60), ("sjuttio", 70), ("åttio", 80), ("nittio", 90),
];
const ORDINALS: [(&str, u64); 20] = [
    ("första", 1), ("andra", 2), ("tredje", 3), ("fjärde", 4), ("femte", 5), ("sjätte", 6), ("sjunde", 7), ("åttonde", 8),
    ("nionde", 9), ("tionde", 10), ("elfte", 11), ("tolfte", 12), ("trettonde", 13), ("fjortonde", 14), ("femtonde", 15),
    ("sextonde", 16), ("sjuttonde", 17), ("artonde", 18), ("nittonde", 19), ("tjugonde", 20),
];
const WEEKDAYS: [&str; 7] = ["måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag"];
const MONTHS: [&str; 12] = ["januari", "februari", "mars", "april", "maj", "juni", "juli", "augusti", "september", "oktober", "november", "december"];

/// One piece of a spoken number.
#[derive(Clone, Copy, PartialEq)]
enum Part {
    Unit(u64),
    Ten(u64),
    Hundred,
    Thousand,
}

/// A word of a text: a number written with digits (already normalized), or a word.
#[derive(Clone, PartialEq)]
enum Word {
    Digits(String),
    Text { lower: String, capital: bool, sentence_start: bool },
    /// A comma or other punctuation between words: a list item ends there, so "noll komma fem,
    /// två" is 0.5 and 2, never 0.52.
    Pause,
}

/// A number as compared: digits without leading zeros, and a decimal part without trailing zeros.
fn normalized(integer: &str, fraction: &str) -> String {
    let integer = integer.trim_start_matches('0');
    let fraction = fraction.trim_end_matches('0');
    let integer = if integer.is_empty() { "0" } else { integer };
    if fraction.is_empty() { integer.to_owned() } else { format!("{integer}.{fraction}") }
}

/// A number with its sign; zero has none.
fn signed(negative: bool, value: String) -> String {
    if negative && value != "0" { format!("-{value}") } else { value }
}

/// The words of a text. A written number stays whole: "2,5" and "2.5" are one decimal, and
/// "2 000" (a space before three digits) is one number; "40–50" is two.
fn words(text: &str) -> Vec<Word> {
    let characters: Vec<char> = text.chars().collect();
    let mut words = Vec::new();
    let mut sentence_start = true;
    let mut negative = false;
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        // A minus sign right before a digit and not after one: "-5" is negative, "40-50" is a range.
        let after_word = index > 0 && characters[index - 1].is_alphanumeric();
        if matches!(character, '-' | '−') && !after_word && characters.get(index + 1).is_some_and(char::is_ascii_digit) {
            negative = true;
            index += 1;
            continue;
        }
        if character.is_ascii_digit() {
            let (mut integer, mut fraction, mut in_fraction) = (String::new(), String::new(), false);
            while let Some(&here) = characters.get(index) {
                let digit_at = |offset: usize| characters.get(index + offset).is_some_and(char::is_ascii_digit);
                if here.is_ascii_digit() {
                    if in_fraction { fraction.push(here) } else { integer.push(here) }
                } else if matches!(here, ',' | '.') && !in_fraction && digit_at(1) {
                    in_fraction = true;
                } else if here == ' ' && !in_fraction && (1..=3).all(digit_at) && !digit_at(4) {
                    // A thousands separator: "2 000".
                } else {
                    break;
                }
                index += 1;
            }
            words.push(Word::Digits(signed(std::mem::take(&mut negative), normalized(&integer, &fraction))));
            sentence_start = false;
        } else if character.is_alphabetic() {
            let mut word = String::new();
            while index < characters.len() && characters[index].is_alphabetic() {
                word.push(characters[index]);
                index += 1;
            }
            words.push(Word::Text { lower: word.to_lowercase(), capital: character.is_uppercase(), sentence_start });
            sentence_start = false;
        } else {
            if !character.is_whitespace() && words.last().is_some_and(|last| *last != Word::Pause) {
                words.push(Word::Pause);
            }
            if matches!(character, '.' | '!' | '?' | ':' | '\n' | '•' | '–' | '-') {
                sentence_start = true;
            }
            index += 1;
        }
    }
    words
}

/// A spoken number word split into its pieces, longest first: "nittonhundrafemton" is 19, hundred,
/// 15; "tvåtusen" is 2, thousand. `None` when the word is not made only of number pieces.
fn parts(word: &str) -> Option<Vec<Part>> {
    let pieces = UNITS.iter().map(|(name, value)| (*name, Part::Unit(*value)))
        .chain(TENS.iter().map(|(name, value)| (*name, Part::Ten(*value))))
        .chain([("hundra", Part::Hundred), ("tusen", Part::Thousand)]);
    let pieces: Vec<(&str, Part)> = pieces.collect();
    let mut rest = word;
    let mut found = Vec::new();
    while !rest.is_empty() {
        let (name, part) = pieces.iter().filter(|(name, _)| rest.starts_with(name)).max_by_key(|(name, _)| name.len())?;
        found.push(*part);
        rest = &rest[name.len()..];
    }
    (!found.is_empty()).then_some(found)
}

/// An ordinal word ("tredje", "tjugoförsta"), read only in quotes.
fn ordinal(word: &str) -> Option<u64> {
    if let Some((_, value)) = ORDINALS.iter().find(|(name, _)| *name == word) {
        return Some(*value);
    }
    let (tens, rest) = TENS.iter().find_map(|(name, value)| word.strip_prefix(name).map(|rest| (*value, rest)))?;
    ORDINALS[..9].iter().find(|(name, _)| *name == rest).map(|(_, value)| tens + value)
}

/// Reads one spoken number from consecutive pieces: "två tusen" is 2000 (never 2 and 1000),
/// "tjugo fem" is 25, but "tre fyra" is two numbers.
#[derive(Default)]
struct Spoken {
    total: u64,
    current: u64,
    last: Option<Part>,
    numbers: Vec<u64>,
}

impl Spoken {
    fn push(&mut self, part: Part) {
        let starts_new = match (self.last, part) {
            (Some(Part::Unit(_)), Part::Unit(_) | Part::Ten(_)) | (Some(Part::Ten(_)), Part::Ten(_)) => true,
            (Some(Part::Ten(_)), Part::Unit(value)) => value >= 10,
            _ => false,
        };
        if starts_new {
            self.finish();
        }
        match part {
            Part::Unit(value) | Part::Ten(value) => self.current += value,
            Part::Hundred => self.current = self.current.max(1) * 100,
            Part::Thousand => {
                self.total += self.current.max(1) * 1_000;
                self.current = 0;
            }
        }
        self.last = Some(part);
    }

    fn finish(&mut self) {
        if self.last.is_some() {
            self.numbers.push(self.total + self.current);
        }
        *self = Self { numbers: std::mem::take(&mut self.numbers), ..Self::default() };
    }
}

/// Every number in a text as compared. In a quote (`quote`) ordinals count, and "en" or "ett"
/// count too; in the text they are ordinary words ("en sammanfattning", "den andra delen").
/// "komma" between two numbers makes a decimal ("två komma fem" is 2.5).
fn numbers(words: &[Word], quote: bool) -> Vec<String> {
    /// What the words say about numbers, in order, before decimals and signs are put together.
    enum Piece {
        Number(String),
        Comma,
        Minus,
        /// Anything else, including a sentence boundary: no number continues across it.
        Break,
    }
    let mut pieces = Vec::new();
    let mut spoken = Spoken::default();
    let flush = |spoken: &mut Spoken, pieces: &mut Vec<Piece>| {
        spoken.finish();
        pieces.extend(std::mem::take(&mut spoken.numbers).into_iter().map(|value| Piece::Number(value.to_string())));
    };
    for word in words {
        match word {
            Word::Digits(value) => {
                flush(&mut spoken, &mut pieces);
                pieces.push(Piece::Number(value.clone()));
            }
            Word::Pause => {
                flush(&mut spoken, &mut pieces);
                pieces.push(Piece::Break);
            }
            Word::Text { lower, sentence_start, .. } => {
                // "tjugo. En sammanfattning" is twenty and then a new sentence, never 21.
                if *sentence_start {
                    flush(&mut spoken, &mut pieces);
                    pieces.push(Piece::Break);
                }
                let article = !quote && matches!(lower.as_str(), "en" | "ett") && spoken.last.is_none();
                match parts(lower).filter(|_| !article) {
                    Some(found) => found.into_iter().for_each(|piece| spoken.push(piece)),
                    None => {
                        flush(&mut spoken, &mut pieces);
                        pieces.push(match lower.as_str() {
                            "komma" => Piece::Comma,
                            "minus" => Piece::Minus,
                            _ => ordinal(lower).filter(|_| quote).map_or(Piece::Break, |value| Piece::Number(value.to_string())),
                        });
                    }
                }
            }
        }
    }
    flush(&mut spoken, &mut pieces);
    // "två komma fem" is 2.5 and "noll komma noll fem" is 0.05: every number after "komma" adds
    // its digits to the decimals, so leading zeros stay. "minus fem" is -5.
    let mut found = Vec::new();
    let mut index = 0;
    while index < pieces.len() {
        let negative = matches!(pieces[index], Piece::Minus);
        let start = index + usize::from(negative);
        let Some(Piece::Number(whole)) = pieces.get(start) else {
            index += 1;
            continue;
        };
        index = start + 1;
        let mut value = whole.clone();
        if !whole.contains('.') && matches!(pieces.get(index), Some(Piece::Comma)) {
            let mut decimals = String::new();
            let mut next = index + 1;
            while let Some(Piece::Number(digits)) = pieces.get(next) {
                if digits.contains('.') || digits.starts_with('-') {
                    break;
                }
                decimals.push_str(digits);
                next += 1;
            }
            if !decimals.is_empty() {
                value = normalized(whole, &decimals);
                index = next;
            }
        }
        found.push(if negative && !value.starts_with('-') { signed(true, value) } else { value });
    }
    found
}

/// A word that names a weekday or a month ("fredagen", "fredags", "mars"), as its base form.
fn calendar_word(word: &str) -> Option<&'static str> {
    WEEKDAYS.iter().find(|day| word.starts_with(*day)).or_else(|| MONTHS.iter().find(|month| word == **month)).copied()
}

/// A name without its genitive s, so "Karls" matches "Karl" but "Karlstad" does not.
fn name_stem(word: &str) -> &str {
    // "Bos" is Bo's: a name of two letters still has a genitive.
    if word.chars().count() >= 3 { word.strip_suffix('s').unwrap_or(word) } else { word }
}

/// True when every number, weekday, month and name in `text` is also in `quote`.
pub fn follow_quote(text: &str, quote: &str) -> bool {
    let quote_words = words(quote);
    let quote_numbers = numbers(&quote_words, true);
    let quote_text: Vec<&str> = quote_words.iter().filter_map(|word| match word {
        Word::Text { lower, .. } => Some(lower.as_str()),
        Word::Digits(_) | Word::Pause => None,
    }).collect();
    let text_words = words(text);
    if !numbers(&text_words, false).iter().all(|value| quote_numbers.contains(value)) {
        return false;
    }
    text_words.iter().all(|word| {
        let Word::Text { lower, capital, sentence_start } = word else { return true };
        if let Some(base) = calendar_word(lower) {
            return quote_text.iter().any(|quoted| calendar_word(quoted) == Some(base));
        }
        // A capital inside a sentence is a name; a number word is not ("Tre" after a colon).
        if *capital && !*sentence_start && parts(lower).is_none() {
            let stem = name_stem(lower);
            return quote_text.iter().any(|quoted| name_stem(quoted) == stem);
        }
        true
    })
}

#[cfg(test)]
mod tests {
    use super::follow_quote;

    #[test]
    fn a_wrong_day_number_or_name_fails() {
        assert!(!follow_quote("Provet är på fredag.", "provet är på torsdag"));
        assert!(!follow_quote("Läs sidorna 40–52.", "läs sidorna fyrtio till femtio"));
        assert!(!follow_quote("Kriget slutade 1815 med Wellington.", "kriget slutade 1815 med Napoleon"));
        assert!(!follow_quote("Provet är den 3 december.", "provet är den fjärde december"));
        assert!(!follow_quote("Tre uppgifter till måndag.", "fyra uppgifter till måndag"));
        // A number is compared whole (CodeRabbit on #33).
        assert!(!follow_quote("Koncentrationen är 5,2 procent.", "Koncentrationen är 2,5 procent."));
        assert!(!follow_quote("Koncentrationen är 5,2 procent.", "koncentrationen är två komma fem procent"));
        assert!(!follow_quote("Läs sidan 2.", "Läs sidan två tusen."));
        assert!(!follow_quote("Läs om Karl.", "Läs om Karlstad."));
        // The sign, spoken decimals and sentence boundaries (CodeRabbit on #33, second round).
        assert!(!follow_quote("Temperaturen är 5 grader.", "Temperaturen är -5 grader."));
        assert!(!follow_quote("Temperaturen är 5 grader.", "temperaturen är minus fem grader"));
        assert!(!follow_quote("Koncentrationen är 5 procent.", "Koncentrationen är noll komma noll fem procent."));
        assert!(!follow_quote("Läs sidan 21.", "Läs sidan tjugo. En sammanfattning ska lämnas in."));
        assert!(!follow_quote("Resultatet är 0,52.", "Resultaten är noll komma fem, två och tre."), "a list comma ends the decimals");
    }

    #[test]
    fn the_same_facts_in_other_words_pass() {
        assert!(follow_quote("Provet är på fredag.", "provet blir nu på fredagen"));
        assert!(follow_quote("20 % av 50 är 10.", "tjugo procent av femtio är tio"));
        assert!(follow_quote("Provet är den 3 december.", "provet är den tredje december"));
        assert!(follow_quote("Napoleons fälttåg 1812.", "napoleon gick mot moskva 1812"));
        assert!(follow_quote("Läs kapitel 25.", "läs kapitel tjugofem"));
        assert!(follow_quote("Läs om Karls resa.", "Läs om Karl."), "a genitive s on either side");
        assert!(follow_quote("Läs sidan 2000.", "Läs sidan två tusen."));
        assert!(follow_quote("Läs sidan 2 000.", "läs sidan tvåtusen"));
        assert!(follow_quote("Kriget började 1915.", "det började nittonhundrafemton"));
        assert!(follow_quote("Koncentrationen är 2,5 procent.", "koncentrationen är två komma fem procent"));
        assert!(follow_quote("Koncentrationen är 2.5 procent.", "Koncentrationen är 2,5 procent."));
        assert!(follow_quote("Läs sidorna 40–50.", "läs sidorna fyrtio till femtio"));
        assert!(follow_quote("Läs sidorna 40-50.", "läs sidorna fyrtio till femtio"), "a hyphen between numbers is a range");
        assert!(follow_quote("Temperaturen är -5 grader.", "temperaturen är minus fem grader"));
        assert!(follow_quote("Koncentrationen är 0,05 procent.", "Koncentrationen är noll komma noll fem procent."));
        assert!(follow_quote("Läs sidan 20.", "Läs sidan tjugo. En sammanfattning ska lämnas in."));
        assert!(follow_quote("Läs sidan 21.", "läs sidan tjugo ett"), "one number within a sentence");
        assert!(follow_quote("Läs om Bos resa.", "Läs om Bo."));
        assert!(follow_quote("Resultatet är 0,5.", "Resultaten är noll komma fem, två och tre."));
        assert!(follow_quote("Gör en sammanfattning av ett kapitel.", "skriv om kapitlet"), "articles are not numbers");
        assert!(follow_quote("Repetera: Fotosyntesen kräver ljus.", "fotosyntesen behöver ljus"), "a capital after a colon starts a sentence");
        assert!(follow_quote("Den andra delen är viktigast.", "det här är viktigast"), "an ordinal word in the text is not a number");
    }
}
