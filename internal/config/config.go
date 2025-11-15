package config

import (
	"crypto/md5"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// LoadConfig loads configuration from a YAML file.
// If path is empty, it searches for config files in default locations.
func LoadConfig(path string) (*ProcTmuxConfig, error) {
	if path == "" {
		// Try to load from default file paths in order
		defaultPaths := []string{"proctmux.yaml", "proctmux.yml", "procmux.yaml", "procmux.yml"}
		for _, defaultPath := range defaultPaths {
			if _, err := os.Stat(defaultPath); err == nil {
				path = defaultPath
				break
			}
		}

		// If path is still empty, all defaults failed
		if path == "" {
			return nil, fmt.Errorf("config file not found in default locations")
		}
	}

	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var cfg ProcTmuxConfig
	if err := yaml.NewDecoder(f).Decode(&cfg); err != nil {
		return nil, err
	}

	cfg = applyDefaults(cfg)
	return &cfg, nil
}

// ToHash generates an MD5 hash of the configuration for change detection
func (cfg *ProcTmuxConfig) ToHash() (string, error) {
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return "", err
	}
	sum := md5.Sum(data)
	return fmt.Sprintf("%x", sum), nil
}
