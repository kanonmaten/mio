//! The "Mio glöd" theme, light and dark, following the desktop's color scheme.

use gpui_kit::App;
use gpui_kit::component::{Theme, ThemeRegistry};

const THEME_SET: &str = include_str!("../themes/mio-glod.json");
const LIGHT: &str = "Mio glöd ljus";
const DARK: &str = "Mio glöd mörk";

/// Registers both variants as the app's light and dark theme and applies the system's scheme.
pub fn init(cx: &mut App) {
    ThemeRegistry::global_mut(cx)
        .load_themes_from_str(THEME_SET)
        .expect("the bundled theme is valid");
    let registry = ThemeRegistry::global(cx).themes();
    let light = registry.get(LIGHT).expect("light variant is bundled").clone();
    let dark = registry.get(DARK).expect("dark variant is bundled").clone();
    Theme::update(cx, |theme| {
        theme.light_theme = light;
        theme.dark_theme = dark;
    });
    Theme::sync_system_appearance(None, cx);
}

#[cfg(test)]
mod tests {
    use gpui_kit::component::ThemeSet;

    #[test]
    fn bundled_theme_has_both_variants() {
        let set: ThemeSet = serde_json::from_str(super::THEME_SET).expect("valid theme JSON");
        let names: Vec<&str> = set.themes.iter().map(|theme| theme.name.as_ref()).collect();
        assert_eq!(names, [super::DARK, super::LIGHT]);
    }
}
