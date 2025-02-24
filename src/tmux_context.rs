use std::io::Error;
use std::process::Output;

use crate::tmux;

pub struct TmuxContext {
    detached_session: String,
    session: String,
    window: usize,
    pane: usize
}

pub fn create_tmux_context(detached_session: String) -> Result<TmuxContext, Error> {
    let session = match String::from_utf8(tmux::current_session()?.stdout) {
        Ok(val) => val.replace("\n", ""),
        Err(e) => panic!("Error: Could not retrieve tmux session id: {}", e)
    };
    let window = match String::from_utf8(tmux::current_window()?.stdout) {
        Ok(val) => val.replace("\n", ""),
        Err(e) => panic!("Error: Could not retrieve tmux window id: {}", e)
    };
    let pane = match String::from_utf8(tmux::current_pane()?.stdout) {
        Ok(val) => val.replace("\n", ""),
        Err(e) => panic!("Error: Could not retrieve tmux pane id: {}", e)
    };

    let window_id = match window.parse() {
        Ok(i) => i,
        Err(e) => panic!("Error: Failed to parse tmux window {}: {}", window, e)
    };
    let pane_id = match pane.parse() {
        Ok(i) => i,
        Err(e) => panic!("Error: Failed to parse tmux pane {}: {}", pane, e)
    };

    Ok(TmuxContext {
        detached_session,
        session,
        window: window_id,
        pane: pane_id,
    })
}

impl TmuxContext {
    pub fn prepare(&self) -> Result<Output, Error> {
        tmux::start_detached_session(&self.detached_session)?;
        tmux::set_remain_on_exit(&self.session, self.window, true)
    }

    pub fn cleanup(&self) -> Result<Output, Error> {
        tmux::kill_session(&self.detached_session)?;
        tmux::set_remain_on_exit(&self.session, self.window, false)
    }

    pub fn break_pane(&self, source_pane: usize, dest_window: usize, window_label: &str) -> Result<Output, Error> {
        tmux::break_pane(
            &self.session,
            self.window,
            source_pane,
            &self.detached_session,
            dest_window,
            window_label)?;
        tmux::set_remain_on_exit(&self.detached_session, dest_window, true)
    }

    pub fn join_pane(&self, target_window: usize) -> Result<usize, Error> {
        tmux::join_pane(
            &self.detached_session,
            target_window,
            &self.session,
            self.window,
            self.pane
        )?;
        Ok(self.pane + 1)
    }

    pub fn create_pane(&self, command: &str) -> Result<usize, Error> {
        let pane = tmux::create_pane(&self.session, self.window, self.pane, command)?;

        match String::from_utf8(pane.stdout) {
            Ok(val) => match val.replace("\n", "").parse() {
                Ok(i) => Ok(i),
                Err(_) => Err(Error::new(
                    std::io::ErrorKind::Other,
                    "Error: Could not convert create_pane output to int"
                ))
            },
            Err(_) => Err(Error::new(std::io::ErrorKind::Other, "Error: Could not parse create_pane output"))
        }
    }
}
