package main

import (
	"errors"
	"testing"
)

type fakeEngine struct {
	running, fail bool
	calls         int
}

func (e *fakeEngine) Apply(s settings) error {
	e.calls++
	if e.fail {
		return errors.New("engine config rejected")
	}
	e.running = s.Enabled
	return nil
}
func (e *fakeEngine) Running() bool { return e.running }
func (e *fakeEngine) Restart() error {
	e.running = true
	return nil
}

func TestRepeatedUpdatesAndControllerRecovery(t *testing.T) {
	e := &fakeEngine{}
	c := controller{engine: e}
	s := sampleSettings()
	for _, id := range []string{"start", "site-1", "site-2", "strategy-1", "strategy-2"} {
		s.Sites = append(s.Sites, site{Host: id + ".example.com", Route: "direct"})
		c.apply(request{Version: 1, ID: id, Settings: rawSettings(s)})
		if c.status.ID != id || c.status.State != "running" || c.status.Error != "" {
			t.Fatalf("update not acknowledged: %+v", c.status)
		}
	}
	if e.calls != 5 {
		t.Fatal("updates did not reach the installed controller")
	}
	e.running = false
	if !c.recover() || !e.running {
		t.Fatal("engine exit was not recovered")
	}
	s.Enabled = false
	c.apply(request{Version: 1, ID: "stop", Settings: rawSettings(s)})
	if c.status.State != "stopped" || c.recover() {
		t.Fatal("stopped engine was restarted")
	}
}

func TestFailedUpdateKeepsLastAppliedSettings(t *testing.T) {
	e := &fakeEngine{}
	c := controller{engine: e}
	first := rawSettings(sampleSettings())
	c.apply(request{Version: 1, ID: "first", Settings: first})
	e.fail = true
	s := sampleSettings()
	s.Strategy = "general-alt"
	c.apply(request{Version: 1, ID: "failed", Settings: rawSettings(s)})
	if c.status.ID != "failed" || c.status.Error == "" || string(c.status.Settings) != string(first) || !e.running {
		t.Fatalf("failed apply lost the previous configuration: %+v", c.status)
	}
	e.running = false
	if !c.recover() || c.status.Error == "" {
		t.Fatal("engine recovery incorrectly turned a failed update into success")
	}
	before := e.calls
	c.apply(request{Version: 2, ID: "unsupported", Settings: first})
	if e.calls != before || c.status.Error == "" {
		t.Fatal("unsupported request reached the engine")
	}
}
