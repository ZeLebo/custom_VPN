package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFileProtocolAppliesRepeatedRequests(t *testing.T) {
	data, base := t.TempDir(), t.TempDir()
	statusPath := filepath.Join(base, "control-status.json")
	input := filepath.Join(data, "control-request.json")
	e := &fakeEngine{}
	c := &controller{engine: e, status: status{Version: 1}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		serve(ctx, c, data, statusPath, uint32(os.Getuid()), 5*time.Millisecond)
		close(done)
	}()
	defer func() { cancel(); <-done }()
	wait := func(id string) status {
		t.Helper()
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			var reply status
			if raw, err := os.ReadFile(statusPath); err == nil && json.Unmarshal(raw, &reply) == nil && reply.ID == id {
				return reply
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatal("controller did not acknowledge request", id)
		return status{}
	}
	s := sampleSettings()
	for _, id := range []string{"start", "site-one", "site-two", "strategy-one", "stop"} {
		s.Enabled = id != "stop"
		s.Sites = []site{{Host: id + ".example.com", Route: "direct"}}
		req := request{Version: 1, ID: id, Settings: rawSettings(s)}
		raw, err := json.Marshal(req)
		if err != nil {
			t.Fatal(err)
		}
		if err = atomicWrite(input, raw); err != nil {
			t.Fatal(err)
		}
		reply := wait(id)
		if reply.Error != "" || string(reply.Settings) != string(req.Settings) {
			t.Fatalf("controller lost settings: %+v", reply)
		}
	}
	if reply := wait("stop"); reply.State != "stopped" {
		t.Fatal("stop did not retain the controller")
	}
}

func TestDartSettingsFixture(t *testing.T) {
	raw, err := os.ReadFile("../../test/fixtures/zapret_control_settings.json")
	if err != nil {
		t.Fatal(err)
	}
	s, err := parseSettings(raw)
	if err != nil || len(s.Sites) < 3 || len(s.CustomHosts) != 1 || s.CustomHosts[0] != "sub.example.com" {
		t.Fatalf("Dart and Go settings contracts differ: %+v %v", s, err)
	}
}
