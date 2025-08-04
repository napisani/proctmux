use crate::state::Mutator;

#[derive(Clone, Debug)]
pub struct GUIState {
    pub messages: Vec<String>,
    pub filter_text: Option<String>,
    pub entering_filter_text: bool,
}

pub struct GUIStateMutation {
    init_state: GUIState,
}

impl Mutator<GUIState> for GUIStateMutation {
    fn on(state: &GUIState) -> Self {
        GUIStateMutation {
            init_state: state.clone(),
        }
    }

    fn commit(self) -> GUIState {
        self.init_state
    }
}

impl GUIStateMutation {
    pub fn set_filter_text(mut self, text: Option<String>) -> Self {
        self.init_state.filter_text = text;
        self
    }

    pub fn start_entering_filter(mut self) -> Self {
        self.init_state.entering_filter_text = true;
        self
    }

    pub fn stop_entering_filter(mut self) -> Self {
        self.init_state.entering_filter_text = false;
        self
    }

    pub fn add_message(mut self, message: String) -> Self {
        self.init_state.messages.push(message);
        self
    }

    pub fn clear_messages(mut self) -> Self {
        self.init_state.messages.clear();
        self
    }
}
