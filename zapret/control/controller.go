package main

import (
	"encoding/json"
	"fmt"
)

type backend interface {
	Apply(settings) error
	Running() bool
	Restart() error
}

type controller struct {
	engine        backend
	status        status
	recoveryError bool
}

func (c *controller) apply(req request) {
	c.status.Version = 1
	c.status.ID = req.ID
	c.status.Error = ""
	c.recoveryError = false
	if req.Version != 1 || !requestIDPattern.MatchString(req.ID) {
		c.status.Error = "unsupported request version or invalid ID"
		return
	}
	s, err := parseSettings(req.Settings)
	if err == nil {
		err = c.engine.Apply(s)
	}
	if err != nil {
		c.status.Error = err.Error()
	} else {
		c.status.Settings = append(json.RawMessage(nil), req.Settings...)
	}
	c.updateState()
}

func (c *controller) updateState() {
	if c.engine.Running() {
		c.status.State = "running"
	} else {
		c.status.State = "stopped"
	}
}

func (c *controller) recover() bool {
	if c.engine.Running() || len(c.status.Settings) == 0 {
		return false
	}
	s, err := parseSettings(c.status.Settings)
	if err != nil || !s.Enabled {
		return false
	}
	if err = c.engine.Restart(); err != nil {
		if c.status.Error == "" || c.recoveryError {
			c.status.Error = fmt.Sprintf("engine restart failed: %v", err)
			c.recoveryError = true
		}
	} else if c.recoveryError {
		c.status.Error = ""
		c.recoveryError = false
	}
	c.updateState()
	return true
}
