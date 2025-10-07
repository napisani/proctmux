package proctmux

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
)

type SignalClient struct {
	baseURL string
	port    int
}

func NewSignalClient(cfg *ProcTmuxConfig) (*SignalClient, error) {
	if !cfg.SignalServer.Enable {
		return nil, errors.New("signal server is not enabled in config")
	}
	if cfg.SignalServer.Port == 0 {
		return nil, errors.New("signal server port is not set in config")
	}
	if cfg.SignalServer.Host == "" {
		return nil, errors.New("signal server host is not set in config")
	}
	return &SignalClient{baseURL: cfg.SignalServer.Host, port: cfg.SignalServer.Port}, nil
}

func (c *SignalClient) do(method, path string) ([]byte, error) {
	urlStr := fmt.Sprintf("http://%s:%d%s", c.baseURL, c.port, path)
	req, _ := http.NewRequest(method, urlStr, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		var m map[string]any
		_ = json.Unmarshal(body, &m)
		if s, ok := m["error"].(string); ok && s != "" {
			return nil, fmt.Errorf("%s", s)
		}
		return nil, fmt.Errorf("%s", string(body))
	}
	return body, nil
}

func (c *SignalClient) RestartProcess(name string) error {
	q := url.PathEscape(name)
	_, err := c.do(http.MethodPost, "/restart-by-name/"+q)
	return err
}

func (c *SignalClient) StopProcess(name string) error {
	q := url.PathEscape(name)
	_, err := c.do(http.MethodPost, "/stop-by-name/"+q)
	return err
}

func (c *SignalClient) StartProcess(name string) error {
	log.Printf("Client Requesting Starting process: %s", name)
	q := url.PathEscape(name)
	_, err := c.do(http.MethodPost, "/start-by-name/"+q)
	return err
}

func (c *SignalClient) RestartRunning() error {
	_, err := c.do(http.MethodPost, "/restart-running")
	return err
}

func (c *SignalClient) StopRunning() error {
	_, err := c.do(http.MethodPost, "/stop-running")
	return err
}

func (c *SignalClient) GetProcessList() ([]byte, error) {
	return c.do(http.MethodGet, "/")
}
