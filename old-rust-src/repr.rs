/*
    A module that provides handy representation / conversion fucntions
*/
use crate::{
    constants::{ANSI_PREFIX, DOWN, UP},
    frame::ColoredSegment,
    process::{Process, ProcessStatus},
    state::State,
};
use std::error::Error;
use termion::{
    color::{self, Color},
    event::Key,
};
pub fn get_status_arrow_and_color(state: &State, process: &Process) -> ColoredSegment {
    match process.status {
        ProcessStatus::Running => {
            let fg = color_from_config_string(&state.config.style.status_running_color)
                .unwrap_or(Box::new(color::Green));
            ColoredSegment::new_basic(fg, format!(" {}", UP))
        }
        ProcessStatus::Halting => {
            let fg = color_from_config_string(&state.config.style.status_halting_color)
                .unwrap_or(Box::new(color::Yellow));
            ColoredSegment::new_basic(fg, format!(" {}", DOWN))
        }
        ProcessStatus::Halted => {
            let fg = color_from_config_string(&state.config.style.status_stopped_color)
                .unwrap_or(Box::new(color::Red));
            ColoredSegment::new_basic(fg, format!(" {}", DOWN))
        }
    }
}

pub fn color_from_config_string(s: &str) -> Result<Box<dyn Color>, Box<dyn Error>> {
    // TODO there might be a better way to do this.
    // i was trying to retain backward compatibility with procmux config as much as possible
    // which this does, but i admit its fugly
    let config_str = s.to_lowercase();
    if config_str.starts_with(ANSI_PREFIX) {
        let config_str = config_str.trim_start_matches(ANSI_PREFIX);
        let c: Box<dyn Color> = match config_str {
            "red" => Box::new(color::Red),
            "green" => Box::new(color::Green),
            "blue" => Box::new(color::Blue),
            "yellow" => Box::new(color::Yellow),
            "cyan" => Box::new(color::Cyan),
            "magenta" => Box::new(color::Magenta),
            "black" => Box::new(color::Black),
            "white" => Box::new(color::White),
            "lightred" => Box::new(color::LightRed),
            "lightgreen" => Box::new(color::LightGreen),
            "lightblue" => Box::new(color::LightBlue),
            "lightyellow" => Box::new(color::LightYellow),
            "lightcyan" => Box::new(color::LightCyan),
            "lightmagenta" => Box::new(color::LightMagenta),
            "lightblack" => Box::new(color::LightBlack),
            "lightwhite" => Box::new(color::LightWhite),
            _ => return Err(Box::from("Unknown color")),
        };
        return Ok(c);
    }
    let mut parts = config_str.split(",");
    let r = parts.next().unwrap().parse::<u8>()?;
    let g = parts.next().unwrap().parse::<u8>()?;
    let b = parts.next().unwrap().parse::<u8>()?;
    Ok(Box::new(color::Rgb(r, g, b)))
}

pub fn key_to_str(key: &Key) -> String {
    fn to_printable_char(c: &char) -> char {
        if *c == '\n' {
            '↵'
        } else {
            *c
        }
    }
    match key {
        Key::Char(c) => format!("{}", to_printable_char(c)),
        Key::Alt(c) => format!("⎇-{}", to_printable_char(c)),
        Key::Ctrl(c) => format!("^-{}", to_printable_char(c)),
        Key::Left => "←".to_string(),
        Key::Right => "→".to_string(),
        Key::Up => "↑".to_string(),
        Key::Down => "↓".to_string(),
        Key::Backspace => "⎵".to_string(),
        Key::Delete => "⌫".to_string(),
        Key::End => "end".to_string(),
        Key::Esc => "esc".to_string(),
        Key::F(i) => format!("fn-{}", i),
        Key::Home => "home".to_string(),
        Key::Insert => "ins".to_string(),
        Key::Null => "null".to_string(),
        Key::PageDown => "pgdn".to_string(),
        Key::PageUp => "pgup".to_string(),
        Key::BackTab => "backtab".to_string(),
        Key::__IsNotComplete => "".to_string(),
    }
}

pub fn keys_to_str(keys: &[Key]) -> String {
    keys.iter()
        .map(key_to_str)
        .collect::<Vec<String>>()
        .join(", ")
}
pub fn keybinding_help(keys: &[Key], label: &str) -> String {
    format!("<{}> {}", keys_to_str(keys), label)
}
