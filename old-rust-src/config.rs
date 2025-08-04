use std::{collections::HashMap, env, ffi::c_int, path::PathBuf};

use serde::{Deserialize, Deserializer, Serialize};
use termion::event::Key;

fn get_current_working_dir() -> std::io::Result<PathBuf> {
    env::current_dir()
}

fn default_general() -> GeneralConfig {
    GeneralConfig {
        detached_session_name: default_detached_session_name(),
        kill_existing_session: default_kill_existing_session(),
    }
}

fn default_layout() -> LayoutConfig {
    LayoutConfig {
        hide_help: default_hide_help(),
        hide_process_description_panel: default_hide_process_description_panel(),
        process_list_width: default_process_list_width(),
        sort_process_list_alpha: default_sort_process_list_alpha(),
        category_search_prefix: default_category_search_prefix(),
    }
}

fn default_style() -> StyleConfig {
    StyleConfig {
        selected_process_color: default_selected_process_color(),
        selected_process_bg_color: default_selected_process_bg_color(),
        unselected_process_color: default_unselected_process_color(),
        status_running_color: default_status_running_color(),
        status_stopped_color: default_status_stopped_color(),
        status_halting_color: default_status_halting_color(),
        pointer_char: default_pointer_char(),
    }
}

#[derive(Serialize, Deserialize, PartialEq, Debug, Clone, Eq)]
pub struct ProcTmuxConfig {
    #[serde(default = "default_general")]
    pub general: GeneralConfig,
    pub procs: HashMap<String, ProcessConfig>,
    pub keybinding: KeybindingConfig,
    pub log_file: String,
    #[serde(default = "default_layout")]
    pub layout: LayoutConfig,
    #[serde(default = "default_style")]
    pub style: StyleConfig,
}

fn default_kill_signal() -> c_int {
    libc::SIGKILL
}
fn current_working_dir() -> String {
    get_current_working_dir()
        .unwrap()
        .to_str()
        .unwrap()
        .to_string()
}
fn default_autostart() -> bool {
    false
}
fn default_autofocus() -> bool {
    false
}
fn default_quit_keybinding() -> Vec<Key> {
    vec![Key::Char('q')]
}
fn default_start_keybinding() -> Vec<Key> {
    vec![Key::Char('s')]
}
fn default_stop_keybinding() -> Vec<Key> {
    vec![Key::Char('x')]
}
fn default_up_keybinding() -> Vec<Key> {
    vec![Key::Char('k'), Key::Up]
}
fn default_down_keybinding() -> Vec<Key> {
    vec![Key::Char('j'), Key::Down]
}
fn default_filter_keybinding() -> Vec<Key> {
    vec![Key::Char('/')]
}
fn default_filter_submit_keybinding() -> Vec<Key> {
    vec![Key::Char('\n')]
}
fn default_switch_focus_submit_keybinding() -> Vec<Key> {
    vec![Key::Ctrl('w')]
}
fn deserialize_kill_signal<'de, D>(deserializer: D) -> Result<c_int, D::Error>
where
    D: Deserializer<'de>,
{
    let signal: String = Deserialize::deserialize(deserializer)?;
    match signal.as_str() {
        "SIGKILL" => Ok(libc::SIGKILL),
        "SIGINT" => Ok(libc::SIGINT),
        "SIGTERM" => Ok(libc::SIGTERM),
        _ => panic!("Could not deserialize kill signal: {}", signal),
    }
}
fn deserialize_keybinding_notation<'de, D>(deserializer: D) -> Result<Vec<Key>, D::Error>
where
    D: Deserializer<'de>,
{
    // map any textual representations of keybinding
    // characters into the stdin characters that need to be detected
    let key_codes: Vec<String> = Deserialize::deserialize(deserializer)?;
    let new_codes = key_codes
        .iter()
        .map(|key| {
            if key.to_lowercase().eq("enter") {
                return Key::Char('\n');
            }
            if key.to_lowercase().eq("esc") {
                return Key::Esc;
            }
            if key.to_lowercase().eq("up") {
                return Key::Up;
            }
            if key.to_lowercase().eq("down") {
                return Key::Down;
            }
            if key.to_lowercase().eq("left") {
                return Key::Left;
            }
            if key.to_lowercase().eq("right") {
                return Key::Right;
            }
            if key.to_lowercase().starts_with("a-") && key.len() == 3 {
                if let Some(c) = key.chars().nth(2) {
                    return Key::Alt(c);
                }
            }
            if key.to_lowercase().starts_with("c-") && key.len() == 3 {
                if let Some(c) = key.chars().nth(2) {
                    return Key::Ctrl(c);
                }
            }
            if key.len() == 1 {
                if let Some(c) = key.chars().nth(0) {
                    return Key::Char(c);
                }
            }
            panic!("Could not deserialize key: {}", key);
        })
        .collect();
    Ok(new_codes)
}
#[derive(Serialize, Deserialize, PartialEq, Debug, Clone, Eq)]
pub struct KeybindingConfig {
    #[serde(
        default = "default_quit_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub quit: Vec<Key>,
    #[serde(
        default = "default_start_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub start: Vec<Key>,
    #[serde(
        default = "default_stop_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub stop: Vec<Key>,
    #[serde(
        default = "default_up_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub up: Vec<Key>,
    #[serde(
        default = "default_down_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub down: Vec<Key>,
    #[serde(
        default = "default_filter_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub filter: Vec<Key>,
    #[serde(
        default = "default_filter_submit_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub filter_submit: Vec<Key>,
    #[serde(
        default = "default_switch_focus_submit_keybinding",
        deserialize_with = "deserialize_keybinding_notation"
    )]
    pub switch_focus: Vec<Key>,
}

#[derive(Serialize, Deserialize, PartialEq, Debug, Clone, Eq)]
pub struct ProcessConfig {
    #[serde(default = "default_autostart")]
    pub autostart: bool,
    #[serde(default = "default_autofocus")]
    pub autofocus: bool,
    pub shell: Option<String>,
    pub cmd: Option<Vec<String>>,
    #[serde(default = "current_working_dir")]
    pub cwd: String,
    #[serde(
        default = "default_kill_signal",
        deserialize_with = "deserialize_kill_signal"
    )]
    pub stop: c_int,
    pub env: Option<HashMap<String, Option<String>>>,
    pub add_path: Option<Vec<String>>,
    pub description: Option<String>,
    pub docs: Option<String>,
    pub categories: Option<Vec<String>>,
    pub meta_tags: Option<Vec<String>>,
}

fn default_detached_session_name() -> String {
    "proctmux".to_string()
}

fn default_kill_existing_session() -> bool {
    false
}

#[derive(Serialize, Deserialize, PartialEq, Debug, Clone, Eq)]
pub struct GeneralConfig {
    #[serde(default = "default_detached_session_name")]
    pub detached_session_name: String,
    #[serde(default = "default_kill_existing_session")]
    pub kill_existing_session: bool,
}

fn default_hide_help() -> bool {
    false
}

fn default_hide_process_description_panel() -> bool {
    false
}

fn default_process_list_width() -> usize {
    31
}

fn default_sort_process_list_alpha() -> bool {
    true
}

fn default_category_search_prefix() -> String {
    "cat:".to_string()
}

// fn default_field_replacement_prompt() -> String {
//     "__FIELD_NAME__ ⮕  ".to_string()
// }
#[derive(Serialize, Deserialize, PartialEq, Debug, Clone, Eq)]
pub struct LayoutConfig {
    #[serde(default = "default_hide_help")]
    pub hide_help: bool,
    #[serde(default = "default_hide_process_description_panel")]
    pub hide_process_description_panel: bool,
    #[serde(default = "default_process_list_width")]
    pub process_list_width: usize,
    #[serde(default = "default_sort_process_list_alpha")]
    pub sort_process_list_alpha: bool,
    #[serde(default = "default_category_search_prefix")]
    pub category_search_prefix: String,
    // #[serde(default = "default_field_replacement_prompt")]
    // field_replacement_prompt: str = '__FIELD_NAME__ ⮕  '
}

fn default_selected_process_color() -> String {
    "ansiblack".to_string()
}

fn default_selected_process_bg_color() -> String {
    "ansimagenta".to_string()
}

fn default_unselected_process_color() -> String {
    "ansiblue".to_string()
}

fn default_status_running_color() -> String {
    "ansigreen".to_string()
}

fn default_status_stopped_color() -> String {
    "ansired".to_string()
}

fn default_status_halting_color() -> String {
    "ansiyellow".to_string()
}
fn default_pointer_char() -> String {
    "▶".to_string()
}

#[derive(Serialize, Deserialize, PartialEq, Debug, Clone, Eq)]
pub struct StyleConfig {
    #[serde(default = "default_selected_process_color")]
    pub selected_process_color: String,
    #[serde(default = "default_selected_process_bg_color")]
    pub selected_process_bg_color: String,
    #[serde(default = "default_unselected_process_color")]
    pub unselected_process_color: String,
    #[serde(default = "default_status_running_color")]
    pub status_running_color: String,
    #[serde(default = "default_status_stopped_color")]
    pub status_stopped_color: String,
    // pub placeholder_terminal_bg_color: String,
    #[serde(default = "default_status_halting_color")]
    pub status_halting_color: String,

    #[serde(default = "default_pointer_char")]
    pub pointer_char: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn deserializing_a_proctmux_config_works() {
        let proctmux_config_file = fs::File::open("./proctmux.yaml").unwrap();
        let proctmux_config: ProcTmuxConfig =
            serde_yaml::from_reader(proctmux_config_file).unwrap();
        assert!(!proctmux_config.procs.is_empty());
        let proc = proctmux_config.procs.get("tail log");
        assert!(proc.is_some());
        let proc = proc.unwrap();
        assert!(proc.autostart);
        assert_eq!(
            proc.cwd,
            get_current_working_dir().unwrap().to_str().unwrap()
        );
        assert_eq!(proc.shell, Some("tail -f /tmp/term.log".to_string()));
    }
}
