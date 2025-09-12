package proctmux

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// StartSignalServer starts an HTTP signal server if enabled in cfg.
// Returns a stop function to gracefully shut it down.
func StartSignalServer(cfg *ProcTmuxConfig, controller *Controller) (func(), error) {
	if !cfg.SignalServer.Enable {
		return func() {}, nil
	}

	mux := http.NewServeMux()

	// GET / -> list processes
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var resp struct {
			ProcessList []map[string]interface{} `json:"process_list"`
		}
		resp.ProcessList = []map[string]interface{}{}
		_ = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				p := state.Processes[i]
				if p.ID == DummyProcessID {
					continue
				}
				resp.ProcessList = append(resp.ProcessList, map[string]interface{}{
					"name":        p.Label,
					"running":     p.Status == StatusRunning,
					"index":       p.ID,
					"scroll_mode": false,
				})
			}
			return state, nil
		})
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	// POST /stop-by-name/{name}
	mux.HandleFunc("/stop-by-name/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/stop-by-name/")
		var found bool
		err := controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				if state.Processes[i].Label == name {
					newState, err2 := haltProcess(state, &state.Processes[i])
					if err2 != nil {
						return nil, err2
					}
					if newState != nil {
						state = newState
					}
					found = true
					break
				}
			}
			return state, nil
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if !found {
			http.Error(w, `{"error":"Process not found"}`, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	// POST /start-by-name/{name}
	mux.HandleFunc("/start-by-name/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/start-by-name/")
		var found bool
		err := controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				if state.Processes[i].Label == name {
					// Kill existing pane if present, then start in detached session (background)
					var err error
					newState, err2 := killPane(state, &state.Processes[i])
					if err2 != nil {
						return nil, err2
					}
					if newState != nil {
						state = newState
					}
					proc := state.GetProcessByID(state.Processes[i].ID)
					newState, err = startProcess(state, controller.tmuxContext, proc, true)
					if err != nil {
						return nil, err
					}
					if newState != nil {
						state = newState
					}
					found = true
					break
				}
			}
			return state, nil
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if !found {
			http.Error(w, `{"error":"Process not found"}`, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	waitUntilStopped := func(label string) error {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			stopped := false
			_ = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				p := state.GetProcessByLabel(label)
				if p == nil || p.Status == StatusHalted {
					stopped = true
				}
				return state, nil
			})
			if stopped {
				return nil
			}
			time.Sleep(100 * time.Millisecond)
		}
		return fmt.Errorf("timeout waiting for process to stop")
	}

	// POST /restart-by-name/{name}
	mux.HandleFunc("/restart-by-name/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/restart-by-name/")
		var found bool
		err := controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				if state.Processes[i].Label == name {
					newState, err2 := haltProcess(state, &state.Processes[i])
					if err2 != nil {
						return nil, err2
					}
					if newState != nil {
						state = newState
					}
					found = true
					break
				}
			}
			return state, nil
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if !found {
			http.Error(w, `{"error":"Process not found"}`, http.StatusNotFound)
			return
		}
		if err := waitUntilStopped(name); err != nil {
			http.Error(w, `{"error":"Failed to stop process"}`, http.StatusInternalServerError)
			return
		}
		// start again
		err = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			p := state.GetProcessByLabel(name)
			if p == nil {
				return state, nil
			}
			newState, err := startProcess(state, controller.tmuxContext, p, true)
			if err != nil {
				return nil, err
			}
			if newState != nil {
				state = newState
			}
			return state, nil
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	// POST /restart-running
	mux.HandleFunc("/restart-running", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var runningLabels []string
		_ = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				p := state.Processes[i]
				if p.Status == StatusRunning && p.ID != DummyProcessID {
					runningLabels = append(runningLabels, p.Label)
				}
			}
			return state, nil
		})
		for _, name := range runningLabels {
			_ = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				p := state.GetProcessByLabel(name)
				if p == nil {
					return state, nil
				}
				newState, _ := haltProcess(state, p)
				if newState != nil {
					state = newState
				}
				return state, nil
			})
			_ = waitUntilStopped(name)
			_ = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
				p := state.GetProcessByLabel(name)
				if p == nil {
					return state, nil
				}
				newState, _ := startProcess(state, controller.tmuxContext, p, true)
				if newState != nil {
					state = newState
				}
				return state, nil
			})
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	// POST /stop-running
	mux.HandleFunc("/stop-running", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		_ = controller.LockAndLoad(func(state *AppState) (*AppState, error) {
			for i := range state.Processes {
				p := state.Processes[i]
				if p.Status == StatusRunning && p.ID != DummyProcessID {
					newState, _ := haltProcess(state, &state.Processes[i])
					if newState != nil {
						state = newState
					}
				}
			}
			return state, nil
		})
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	addr := cfg.SignalServer.Host + ":" + strconv.Itoa(cfg.SignalServer.Port)
	server := &http.Server{Addr: addr, Handler: mux}
	go func() {
		log.Printf("Signal server listening on %s", addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("Signal server error: %v", err)
		}
	}()
	return func() { _ = server.Close() }, nil
}
