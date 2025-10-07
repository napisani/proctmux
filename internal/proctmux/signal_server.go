package proctmux

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
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
		log.Printf("Received request to stop process with label %s", name)
		if err := controller.OnKeypressStopWithLabel(name); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
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
		log.Printf("Received request to start process with name: %s", name)
		if err := controller.OnKeypressStartWithLabel(name); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	// POST /restart-by-name/{name}
	mux.HandleFunc("/restart-by-name/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/restart-by-name/")
		if err := controller.OnKeypressRestartWithLabel(name); err != nil {
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
			_ = controller.OnKeypressRestartWithLabel(name)
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
			_ = controller.OnKeypressStopWithLabel(name)
		}
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
