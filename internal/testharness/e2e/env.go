package e2e

import (
	"os"
	"strings"
)

func mergeEnv(extra []string) []string {
	envMap := make(map[string]string)
	for _, kv := range os.Environ() {
		if before, after, ok := strings.Cut(kv, "="); ok {
			key := before
			value := after
			envMap[key] = value
		}
	}
	for _, kv := range extra {
		if before, after, ok := strings.Cut(kv, "="); ok {
			key := before
			value := after
			envMap[key] = value
		}
	}

	result := make([]string, 0, len(envMap))
	for key, value := range envMap {
		result = append(result, key+"="+value)
	}
	return result
}
