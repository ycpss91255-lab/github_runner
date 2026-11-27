package main

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestResolveOwner(t *testing.T) {
	for _, tc := range []struct {
		name    string
		env     string
		host    string
		hostErr error
		want    string
	}{
		{name: "environment wins", env: "configured-owner", host: "runner-host", want: "configured-owner"},
		{name: "hostname fallback", host: "runner-host", want: "runner-host"},
		{name: "hostname error", host: "unusable-host", hostErr: errors.New("hostname lookup failed"), want: "generated-id"},
		{name: "empty hostname", want: "generated-id"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			getenv := func(key string) string {
				if key == "SCALE_SET_OWNER" {
					return tc.env
				}
				return ""
			}
			hostname := func() (string, error) { return tc.host, tc.hostErr }
			newID := func() string { return "generated-id" }

			if got := resolveOwner(getenv, hostname, newID); got != tc.want {
				t.Errorf("owner = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestResolveScriptPath(t *testing.T) {
	prefix := t.TempDir()
	exe := filepath.Join(prefix, "bin", "scaleset-listener")
	for _, tc := range []struct {
		key  string
		name string
	}{
		{key: "HOST_PROBE_CMD", name: "host-probe.sh"},
		{key: "PROVISION_SCRIPT", name: "provision-job.sh"},
		{key: "REAP_SCRIPT", name: "reap.sh"},
	} {
		t.Run(tc.key, func(t *testing.T) {
			t.Setenv(tc.key, "")
			want := filepath.Join(prefix, "listener", tc.name)
			if got := resolveScriptPath(exe, tc.key, tc.name); !filepath.IsAbs(got) || got != want {
				t.Errorf("default script = %q, want absolute path %q", got, want)
			}

			const override = "custom/operator-script"
			t.Setenv(tc.key, override)
			if got := resolveScriptPath(exe, tc.key, tc.name); got != override {
				t.Errorf("configured script = %q, want %q", got, override)
			}
		})
	}
}
