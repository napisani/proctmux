mod args;
mod config;
mod constants;
mod controller;
mod daemon;
mod draw;
mod frame;
mod gui_state;
mod input;
mod process;
mod repr;
mod state;
mod tmux;
mod tmux_context;
mod tmux_daemon;

use std::error::Error;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use args::parse_config_from_args;
use controller::Controller;
use daemon::receive_dead_pids;
use input::input_loop;
use state::State;
use tmux_context::TmuxContext;
use tmux_daemon::TmuxDaemon;

#[macro_use]
extern crate log;

fn main() -> Result<(), Box<dyn Error>> {
    let config = parse_config_from_args()?;

    let file = std::fs::File::create(config.log_file.clone()).unwrap();
    env_logger::builder()
        .target(env_logger::Target::Pipe(Box::new(file)))
        .filter_level(log::LevelFilter::Debug)
        .init();

    info!("Starting proctmux");

    let tmux_context = TmuxContext::new(
        &config.general.detached_session_name,
        config.general.kill_existing_session,
    )?;

    let running = Arc::new(AtomicBool::new(true));
    let mut tmux_daemon_attached = TmuxDaemon::new(&tmux_context.session_id)?;
    let mut tmux_daemon_detached = TmuxDaemon::new(&tmux_context.detached_session_id)?;
    let state = State::new(&config);
    let controller = Arc::new(Mutex::new(Controller::new(
        state,
        tmux_context,
        running.clone(),
    )?));
    let (sender, receiver) = channel();

    receive_dead_pids(receiver, controller.clone());

    /*
    * Creating TmuxDaemon instances (which start tmux processes in control mode) as
    * soon as possible, and then waiting as long as we can to call the
    * listen_for_dead_panes method on each instance (which sends the refresh-client
    * command to the tmux control mode process of the TmuxDaemon instance),
    * is necessary to make sure the refresh-client command succeeds on all
    * machines/environments.

    * When refresh-client is called with -B argument, tmux checks that the
    * CLIENT_CONTROL bit is set. If it isn't the "not a control client"
    * error appears and the subscription is not created. The CLIENT_CONTROL
    * bit should be set when tmux is started with -C argument (control mode).

    * On some machines/environments, the "not a control client" error manifests if
    * listen_for_dead_panes is called too soon after a TmuxDaemon is instantiated.
    * My best guess is this is a timing bug in tmux. Maybe we're calling refresh-client
    * too soon after starting tmux, and the CLIENT_CONTROL bit hasn't been set
    * yet. After enough time has passed (a few milliseconds? maybe not even one?) the
    * refresh-client command will succeed, indicating the CLIENT_CONTROL bit is set.

    * If a tmux bug is identified/fixed this timing should no longer be a concern,
    * listen_for_dead_panes should be callable immediately after instantiating a TmuxDaemon.
    */
    std::thread::sleep(std::time::Duration::from_millis(5));
    tmux_daemon_attached.listen_for_dead_panes(sender.clone())?;
    tmux_daemon_detached.listen_for_dead_panes(sender)?;

    controller.lock().unwrap().on_startup()?;
    input_loop(controller.clone(), config.keybinding, running);

    info!("Exiting proctmux");

    tmux_daemon_attached.kill()?;
    tmux_daemon_detached.kill()?;
    controller.lock().unwrap().on_exit();

    Ok(())
}
