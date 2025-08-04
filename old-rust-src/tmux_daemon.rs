use std::error::Error;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, ExitStatus};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::thread::spawn;

use crate::tmux;

pub struct TmuxDaemon {
    session_id: String,
    process: Child,
    stdout: Option<ChildStdout>,
    stdin: ChildStdin,
    running: Arc<AtomicBool>,
    subscription_name: String,
}

impl TmuxDaemon {
    pub fn new(session_id: &str) -> Result<Self, Box<dyn Error>> {
        info!(
            "Starting tmux control mode (Session {}) process",
            session_id
        );
        let mut process = tmux::control_mode(session_id)?;
        let stdin = process.stdin.take().unwrap();
        let stdout = process.stdout.take();

        Ok(TmuxDaemon {
            session_id: session_id.to_string(),
            process,
            stdout,
            stdin,
            running: Arc::new(AtomicBool::new(true)),
            subscription_name: format!("pane_dead_notification_{}", clean(session_id)),
        })
    }

    fn subscribe_to_pane_dead_notifications(&mut self) -> std::io::Result<()> {
        info!(
            "Starting subscription (Session: {}): {}",
            self.session_id, self.subscription_name
        );
        let cmd = format!(
            "refresh-client -B {}:%*:\"#{{pane_dead}} #{{pane_pid}}\"\n",
            self.subscription_name
        );
        self.stdin.write_all(cmd.as_bytes())
    }

    pub fn kill(&mut self) -> std::io::Result<ExitStatus> {
        info!(
            "Killing tmux control mode process (Session: {})",
            self.session_id
        );
        self.running.store(false, Ordering::Relaxed);
        self.process.kill()?;
        self.process.wait() // make sure stdin is closed
    }

    pub fn listen_for_dead_panes(&mut self, sender: Sender<i32>) -> Result<(), Box<dyn Error>> {
        let mut buf_reader = BufReader::new(self.stdout.take().unwrap());
        let running = self.running.clone();
        let subscription_name = self.subscription_name.clone();
        let session_id = self.session_id.clone();

        spawn(move || {
            while running.load(Ordering::Relaxed) {
                let mut buf = String::new();
                match buf_reader.read_line(&mut buf) {
                    Ok(_) => {
                        if let Some(pid) =
                            parse_pane_dead_notification(buf, &subscription_name, &session_id)
                        {
                            sender.send(pid).unwrap();
                        }
                    }
                    _ => return,
                }
            }
        });

        self.subscribe_to_pane_dead_notifications()?;
        Ok(())
    }
}

fn parse_pane_dead_notification(
    line: String,
    subscription_name: &str,
    session_id: &str,
) -> Option<i32> {
    trace!("Control mode line (Session: {}): {}", session_id, line);
    if line.starts_with(&format!("%subscription-changed {}", subscription_name)) {
        let ss: Vec<&str> = line.split(' ').collect();
        if ss[ss.len() - 2] == "1" {
            return ss[ss.len() - 1].trim().parse().ok();
        }
    }
    None
}

fn clean(s: &str) -> String {
    s.replace("$", "")
}
