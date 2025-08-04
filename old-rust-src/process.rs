use crate::config::ProcessConfig;

#[derive(Clone, Eq, PartialEq, Debug)]
pub enum ProcessStatus {
    Running = 1,
    Halting = 2,
    Halted = 3,
}

#[derive(Clone, Debug)]
pub struct Process {
    pub id: usize,
    pub label: String,
    pub status: ProcessStatus,
    pub pane_id: Option<String>,
    pub pid: Option<i32>,
    pub config: ProcessConfig,
}

impl Process {
    pub fn new(id: usize, label: &str, config: ProcessConfig) -> Self {
        Process {
            id,
            label: label.to_string(),
            status: ProcessStatus::Halted,
            pane_id: None,
            pid: None,
            config,
        }
    }

    pub fn command(&self) -> String {
        self.config.shell.clone().unwrap_or(
            self.config
                .cmd
                .clone()
                .unwrap_or(vec![])
                .into_iter()
                .map(|s| format!("'{}' ", s))
                .collect(),
        )
    }
}
