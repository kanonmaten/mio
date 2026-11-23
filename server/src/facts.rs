//! Whether a short text says what its quote says, as far as rules can tell (user decision
//! 2026-11-23, MIO-46). The quote is already proved to be in the transcript (`exact_quote`); this
//! checks the hard facts in the text beside it: every number, weekday, month and name in the text
//! must also be in the quote. An exam hint "Provet är på fredag" with the quote "provet är på
//! torsdag" fails, so the hint is dropped instead of teaching the wrong day.
//!
//! Only facts are checked, never meaning: "ska inte" turned into "ska" passes. A paraphrased
//! number ("hälften" for "50 procent") fails, which drops a true hint now and then but never
//! passes a wrong number. Spoken numbers in the quote count ("tjugo" is 20, "tredje" is 3), since
//! the transcript writes what was said.

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
const LARGE: [(&str, u64); 3] = [("hundra", 100), ("etthundra", 100), ("tusen", 1_000)];
const WEEKDAYS: [&str; 7] = ["måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag"];
const MONTHS: [&str; 12] = ["januari", "februari", "mars", "april", "maj", "juni", "juli", "augusti", "september", "oktober", "november", "december"];

/// The words of a text with whether each starts a sentence.
fn words(text: &str) -> Vec<(String, bool)> {
    let mut words = Vec::new();
    let (mut word, mut sentence_start) = (String::new(), true);
    let push = |word: &mut String, sentence_start: &mut bool, words: &mut Vec<(String, bool)>| {
        if !word.is_empty() {
            words.push((std::mem::take(word), *sentence_start));
            *sentence_start = false;
        }
    };
    for character in text.chars() {
        // Digits and letters form separate words, so "3:e" and "20%" give the numbers alone.
        let same_kind = word.chars().last().is_none_or(|last| last.is_ascii_digit() == character.is_ascii_digit());
        if character.is_alphanumeric() && same_kind {
            word.push(character);
        } else {
            push(&mut word, &mut sentence_start, &mut words);
            if character.is_alphanumeric() {
                word.push(character);
            } else if matches!(character, '.' | '!' | '?' | ':' | '\n' | '•' | '–' | '-') {
                sentence_start = true;
            }
        }
    }
    push(&mut word, &mut sentence_start, &mut words);
    words
}

/// The value of a spoken number: a cardinal, a compound such as "tjugofem", or, when `ordinals`,
/// an ordinal such as "tredje" or "tjugoförsta".
fn spoken(word: &str, ordinals: bool) -> Option<u64> {
    let simple = UNITS.iter().chain(LARGE.iter()).chain(TENS.iter())
        .chain(ordinals.then_some(ORDINALS.iter()).into_iter().flatten());
    if let Some((_, value)) = simple.clone().find(|(name, _)| *name == word) {
        return Some(*value);
    }
    let (tens, rest) = TENS.iter().find_map(|(name, value)| word.strip_prefix(name).map(|rest| (*value, rest)))?;
    // "ett" to "nio": the units a compound such as "tjugofem" or "trettioen" ends with.
    let units = UNITS[1..11].iter().chain(ordinals.then_some(ORDINALS[..9].iter()).into_iter().flatten());
    units.clone().find(|(name, _)| *name == rest).map(|(_, value)| tens + value)
}

/// Every number a quote holds, written with digits or spoken.
fn quote_numbers(words: &[(String, bool)]) -> Vec<u64> {
    words.iter().filter_map(|(word, _)| word.parse::<u64>().ok().or_else(|| spoken(word, true))).collect()
}

/// A word that names a weekday or a month ("fredagen", "fredags", "mars"), as its base form.
fn calendar_word(word: &str) -> Option<&'static str> {
    WEEKDAYS.iter().find(|day| word.starts_with(*day)).or_else(|| MONTHS.iter().find(|month| word == **month)).copied()
}

/// True when every number, weekday, month and name in `text` is also in `quote`.
pub fn follow_quote(text: &str, quote: &str) -> bool {
    let quote_words: Vec<(String, bool)> = words(quote).into_iter().map(|(word, start)| (word.to_lowercase(), start)).collect();
    let numbers = quote_numbers(&quote_words);
    let quote_has = |check: &dyn Fn(&str) -> bool| quote_words.iter().any(|(word, _)| check(word));
    words(text).into_iter().all(|(original, sentence_start)| {
        let word = original.to_lowercase();
        if let Ok(value) = word.parse::<u64>() {
            return numbers.contains(&value);
        }
        // "en" and "ett" are also articles, so the text may use them freely; ordinals ("andra")
        // double as ordinary words and are only read on the quote's side.
        if !matches!(word.as_str(), "en" | "ett")
            && let Some(value) = spoken(&word, false)
        {
            return numbers.contains(&value);
        }
        if let Some(base) = calendar_word(&word) {
            return quote_has(&|quoted| calendar_word(quoted) == Some(base));
        }
        // A capital inside a sentence is a name. The genitive s is dropped, and the quote may
        // inflect it ("Napoleon" against "Napoleons").
        let is_name = !sentence_start && original.chars().next().is_some_and(char::is_uppercase);
        if is_name {
            let stem = if word.chars().count() > 3 { word.strip_suffix('s').unwrap_or(&word) } else { &word };
            return quote_has(&|quoted| quoted.starts_with(stem));
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
    }

    #[test]
    fn the_same_facts_in_other_words_pass() {
        assert!(follow_quote("Provet är på fredag.", "provet blir nu på fredagen"));
        assert!(follow_quote("20 % av 50 är 10.", "tjugo procent av femtio är tio"));
        assert!(follow_quote("Provet är den 3 december.", "provet är den tredje december"));
        assert!(follow_quote("Napoleons fälttåg 1812.", "napoleon gick mot moskva 1812"));
        assert!(follow_quote("Läs kapitel 25.", "läs kapitel tjugofem"));
        assert!(follow_quote("Gör en sammanfattning av ett kapitel.", "skriv om kapitlet"), "articles are not numbers");
        assert!(follow_quote("Repetera: Fotosyntesen kräver ljus.", "fotosyntesen behöver ljus"), "a capital after a colon starts a sentence");
        assert!(follow_quote("Den andra delen är viktigast.", "det här är viktigast"), "an ordinal word in the text is not a number");
    }
}
