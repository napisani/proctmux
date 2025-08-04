use std::sync::{mpsc::Receiver, Arc, Mutex};
use std::thread::spawn;

use crate::controller::Controller;

pub fn receive_dead_pids(receiver: Receiver<i32>, controller: Arc<Mutex<Controller>>) {
    spawn(move || {
        for pid in receiver {
            trace!("Received dead pid: {}", pid);
            controller.lock().unwrap().on_pid_terminated(pid).unwrap();
        }
    });
}
