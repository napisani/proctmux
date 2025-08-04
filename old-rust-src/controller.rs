use std::error::Error;
use std::io::Stdout;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use termion::raw::RawTerminal;

use crate::draw::{draw_screen, init_screen, prepare_screen_for_exit};
use crate::gui_state::GUIStateMutation;
use crate::process::{Process, ProcessStatus};
use crate::state::{Mutator, State, StateMutation};
use crate::tmux;
use crate::tmux_context::TmuxContext;

pub struct Controller {
    state: Mutex<State>,
    tmux_context: TmuxContext,
    stdout: RawTerminal<Stdout>,
    running: Arc<AtomicBool>,
}

impl Controller {
    pub fn new(
        state: State,
        tmux_context: TmuxContext,
        running: Arc<AtomicBool>,
    ) -> Result<Self, Box<dyn Error>> {
        Ok(Controller {
            state: Mutex::new(state),
            tmux_context,
            stdout: init_screen()?,
            running,
        })
    }

    /*
     * All modifications to the state mutex value can/should be
     * easily done through this method
     */
    fn lock_and_load<F>(&self, f: F) -> Result<(), Box<dyn Error>>
    where
        F: Fn(&State) -> Result<Option<State>, Box<dyn Error>>,
    {
        match self.state.lock() {
            Ok(mut state) => match f(&state) {
                Ok(Some(new_state)) => {
                    *state = new_state;
                    self.check_for_exit(&state);
                    self.draw_screen(&state)
                }
                Ok(None) => Ok(()),
                Err(e) => {
                    return Err(e);
                }
            },
            Err(e) => {
                error!("lock_and_load => Failed to lock state: {}", e);
                Ok(())
            }
        }
    }

    pub fn is_entering_filter_text(&self) -> bool {
        self.state
            .lock()
            .map(|s| s.gui_state.entering_filter_text)
            .unwrap_or(false)
    }

    pub fn filter_text(&self) -> Option<String> {
        self.state
            .lock()
            .map(|s| s.gui_state.filter_text.clone())
            .unwrap_or(None)
    }

    pub fn on_filter_start(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_filter_start");
        self.lock_and_load(|state| {
            let gui_state = GUIStateMutation::on(&state.gui_state)
                .start_entering_filter()
                .commit();
            Ok(Some(
                StateMutation::on(state).set_gui_state(gui_state).commit(),
            ))
        })
    }

    pub fn on_filter_done(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_filter_done");
        self.lock_and_load(|state| {
            let gui_state = GUIStateMutation::on(&state.gui_state)
                .stop_entering_filter()
                .commit();
            Ok(Some(
                StateMutation::on(state).set_gui_state(gui_state).commit(),
            ))
        })
    }

    pub fn on_filter_set(&self, new_filter_text: Option<String>) -> Result<(), Box<dyn Error>> {
        trace!("on_filter_set");
        self.lock_and_load(move |state| {
            let gui_state = GUIStateMutation::on(&state.gui_state)
                .set_filter_text(new_filter_text.clone())
                .commit();
            Ok(Some(
                StateMutation::on(state).set_gui_state(gui_state).commit(),
            ))
        })
    }

    pub fn on_error(&self, err: Box<dyn Error>) -> Result<(), Box<dyn Error>> {
        trace!("on_error");
        self.lock_and_load(|state| {
            let gui_state = GUIStateMutation::on(&state.gui_state)
                .add_message(format!("{}", err))
                .commit();
            Ok(Some(
                StateMutation::on(state).set_gui_state(gui_state).commit(),
            ))
        })
    }

    fn draw_screen(&self, state: &State) -> Result<(), Box<dyn Error>> {
        draw_screen(&self.stdout, state)
    }

    pub fn on_startup(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_startup");
        self.tmux_context.prepare()?;

        self.lock_and_load(|state| {
            let mut new_state = state.clone();
            for process in &state.processes {
                if process.config.autostart {
                    match start_process(&new_state, &self.tmux_context, &process) {
                        Ok(Some(s)) => new_state = s,
                        Ok(None) => {}
                        Err(e) => error!("Error auto-starting process {}: {}", process.label, e),
                    }
                }
            }
            Ok(Some(new_state))
        })
    }

    pub fn on_exit(&self) {
        trace!("on_exit");
        if let Err(e) = self.lock_and_load(|state| {
            Ok(Some(
                state
                    .processes
                    .iter()
                    .filter(|process| process.status == ProcessStatus::Halted)
                    .fold(state.clone(), |acc, process| {
                        match kill_pane(&acc, process) {
                            Ok(Some(s)) => s,
                            Ok(None) => acc,
                            Err(e) => {
                                error!(
                                    "Error killing pane for process {} in on_exit: {}",
                                    process.label, e
                                );
                                acc
                            }
                        }
                    }),
            ))
        }) {
            error!("Error killing panes in on_exit: {}", e);
        }

        if let Err(e) = self.tmux_context.cleanup() {
            error!("Error cleaning up tmux context in on_exit: {}", e);
        }

        if let Err(e) = prepare_screen_for_exit(&self.stdout) {
            error!("Error preparing screen for exit in on_exit: {}", e);
        }
    }

    pub fn on_keypress_quit(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_keypress_quit");
        self.lock_and_load(|state| {
            if state.exiting {
                return Ok(None);
            }
            let new_state = StateMutation::on(state).set_exiting().commit();
            Ok(Some(
                new_state
                    .processes
                    .iter()
                    .filter(|process| process.status != ProcessStatus::Halted)
                    .fold(new_state.clone(), |acc, process| {
                        match halt_process(&acc, Some(process)) {
                            Ok(Some(s)) => s,
                            Ok(None) => acc,
                            Err(e) => {
                                error!(
                                    "Error halting process {} in on_keypress_quit: {}",
                                    process.label, e
                                );
                                acc
                            }
                        }
                    }),
            ))
        })
    }

    pub fn on_keypress_down(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_keypress_down");
        self.lock_and_load(|state| {
            break_pane(state, &self.tmux_context, state.current_proc_id)?;
            let new_state = StateMutation::on(state).next_process().commit();
            match join_pane(&new_state, &self.tmux_context, new_state.current_proc_id) {
                Ok(_) => Ok(Some(new_state)),
                Err(e) => {
                    error!(
                        "Error joining pane (proc id: {}): {}",
                        new_state.current_proc_id, e
                    );
                    Ok(Some(new_state))
                }
            }
        })
    }

    pub fn on_keypress_up(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_keypress_up");
        self.lock_and_load(|state| {
            break_pane(state, &self.tmux_context, state.current_proc_id)?;
            let new_state = StateMutation::on(state).previous_process().commit();
            match join_pane(&new_state, &self.tmux_context, new_state.current_proc_id) {
                Ok(_) => Ok(Some(new_state)),
                Err(e) => {
                    error!(
                        "Error joining pane (proc id: {}): {}",
                        new_state.current_proc_id, e
                    );
                    Ok(Some(new_state))
                }
            }
        })
    }

    pub fn on_keypress_start(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_keypress_start");
        self.lock_and_load(|state| {
            if state.exiting {
                Ok(None)
            } else {
                match state.current_process() {
                    Some(process) => {
                        let kill_pane_state = kill_pane(state, process)?.unwrap_or(state.clone());

                        match start_process(&kill_pane_state, &self.tmux_context, process) {
                            Ok(Some(sp_state)) => {
                                if process.config.autofocus {
                                    trace!("Auto-focusing {}", process.label);
                                    if let Some(e) = focus_active_pane(&sp_state).err() {
                                        error!("Error auto-focusing {}: {}", process.label, e);
                                    }
                                }
                                Ok(Some(sp_state))
                            }
                            Ok(None) => Ok(Some(kill_pane_state)),
                            Err(e) => {
                                error!("Error starting process {}: {}", process.label, e);
                                Ok(Some(kill_pane_state))
                            }
                        }
                    }
                    None => Ok(None),
                }
            }
        })
    }

    pub fn on_keypress_stop(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_keypress_stop");
        self.lock_and_load(|state| halt_process(state, state.current_process()))
    }

    pub fn on_keypress_switch_focus(&self) -> Result<(), Box<dyn Error>> {
        trace!("on_keypress_switch_focus");
        self.lock_and_load(|state| focus_active_pane(state))
    }

    pub fn on_pid_terminated(&self, pid: i32) -> Result<(), Box<dyn Error>> {
        trace!("on_pid_terminated: {}", pid);
        self.lock_and_load(|state| {
            let process = state.get_process_by_pid(pid);
            let new_state = set_process_terminated(state, process);
            if new_state.is_some() {
                info!("pid terminated: {}", pid);
                if let Some(e) = tmux::select_pane(&self.tmux_context.pane_id).err() {
                    error!(
                        "Error focusing proctmux pane after pid {} termination: {}",
                        pid, e
                    );
                }
            }
            Ok(new_state.or(Some(state.clone())))
        })
    }

    pub fn check_for_exit(&self, state: &State) {
        if state.exiting {
            if state
                .processes
                .iter()
                .find(|p| p.status != ProcessStatus::Halted)
                .is_none()
            {
                self.running
                    .store(false, std::sync::atomic::Ordering::Relaxed);
            }
        }
    }
}

fn start_process(
    state: &State,
    tmux_context: &TmuxContext,
    process: &Process,
) -> Result<Option<State>, Box<dyn Error>> {
    if process.status != ProcessStatus::Halted {
        return Ok(None);
    }

    let new_pane = if process.id == state.current_proc_id {
        tmux_context.create_pane(process)
    } else {
        tmux_context.create_detached_pane(process)
    };

    match new_pane {
        Ok(pane_id) => {
            let pid = tmux_context.get_pane_pid(&pane_id).ok();
            info!(
                "Started {} process, pid: {}",
                process.label,
                pid.unwrap_or(-1)
            );
            Ok(Some(
                StateMutation::on(state)
                    .set_process_status(ProcessStatus::Running, process.id)
                    .set_process_pane_id(Some(pane_id), process.id)
                    .set_process_pid(pid, process.id)
                    .commit(),
            ))
        }
        Err(e) => Err(e),
    }
}

fn kill_pane(state: &State, process: &Process) -> Result<Option<State>, Box<dyn Error>> {
    if process.status != ProcessStatus::Halted {
        return Ok(None);
    }

    match &process.pane_id {
        Some(pane_id) => {
            // TODO: will this error if pane id value exists but pane does not?
            match tmux::kill_pane(pane_id) {
                Ok(_) => Ok(Some(
                    StateMutation::on(state)
                        .set_process_pane_id(None, process.id)
                        .commit(),
                )),
                Err(e) => return Err(Box::new(e)),
            }
        }
        None => Ok(None),
    }
}

fn focus_active_pane(state: &State) -> Result<Option<State>, Box<dyn Error>> {
    match state.current_process().and_then(|p| p.pane_id.clone()) {
        Some(pane_id) => Ok(tmux::select_pane(&pane_id).map(|_| None)?),
        None => Ok(None),
    }
}

fn set_process_terminated(state: &State, process: Option<&Process>) -> Option<State> {
    process
        .map(|p| {
            if p.status != ProcessStatus::Halted {
                Some(
                    StateMutation::on(state)
                        .set_process_status(ProcessStatus::Halted, p.id)
                        .set_process_pid(None, p.id)
                        .commit(),
                )
            } else {
                None
            }
        })
        .flatten()
}

fn halt_process(state: &State, process: Option<&Process>) -> Result<Option<State>, Box<dyn Error>> {
    match process {
        Some(p) => {
            if p.status != ProcessStatus::Running {
                return Ok(None);
            }

            match p.pid {
                Some(pid) => {
                    info!(
                        "Sending signal {} to pid {} ({})",
                        p.config.stop, pid, p.label
                    );
                    unsafe { libc::kill(pid, p.config.stop) };
                    Ok(Some(
                        StateMutation::on(state)
                            .set_process_status(ProcessStatus::Halting, p.id)
                            .commit(),
                    ))
                }
                None => Ok(None),
            }
        }
        None => Ok(None),
    }
}

fn break_pane(
    state: &State,
    tmux_context: &TmuxContext,
    process_id: usize,
) -> Result<(), Box<dyn Error>> {
    if let Some(process) = state.get_process(process_id) {
        if let Some(pane_id) = &process.pane_id {
            tmux_context.break_pane(pane_id, process.id, &process.label)?;
        }
    }
    Ok(())
}

fn join_pane(
    state: &State,
    tmux_context: &TmuxContext,
    process_id: usize,
) -> Result<(), Box<dyn Error>> {
    if let Some(process) = state.get_process(process_id) {
        if let Some(pane_id) = &process.pane_id {
            tmux_context.join_pane(pane_id)?;
        }
    }
    Ok(())
}
