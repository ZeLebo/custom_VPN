package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const installedBase = "/Library/Application Support/ZapretMac"

func main() {
	dataRoot := flag.String("data-root", "", "approved user data directory")
	userID := flag.String("uid", "", "owner of approved configuration files")
	flag.Parse()
	uid, err := strconv.ParseUint(*userID, 10, 32)
	if err != nil || uid == 0 || os.Geteuid() != 0 ||
		!strings.HasPrefix(*dataRoot, "/Users/") ||
		!strings.HasSuffix(*dataRoot, "/Library/Application Support/ZapretMac") ||
		filepath.Clean(*dataRoot) != *dataRoot {
		fmt.Fprintln(os.Stderr, "invalid controller installation")
		os.Exit(1)
	}
	r := newRuntime(installedBase, *dataRoot, uint32(uid))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := atomicWrite(filepath.Join(installedBase, "control.pid"), []byte(strconv.Itoa(os.Getpid()))); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer r.stopEngine()
	c := controller{engine: r, status: status{Version: 1, State: "stopped"}}
	statusPath := filepath.Join(installedBase, "control-status.json")
	if raw, err := os.ReadFile(statusPath); err == nil {
		var old status
		if json.Unmarshal(raw, &old) == nil && old.Version == 1 {
			c.status.ID = old.ID
			c.status.Settings = old.Settings
			if s, err := parseSettings(old.Settings); err == nil && s.Enabled {
				if err := r.Apply(s); err != nil {
					c.status.Error = err.Error()
				}
			}
		}
	}
	serve(ctx, &c, *dataRoot, statusPath, uint32(uid), time.Second)
}

func serve(ctx context.Context, c *controller, dataRoot, statusPath string, uid uint32, period time.Duration) {
	ticker := time.NewTicker(period)
	defer ticker.Stop()
	var lastRequest []byte
	writeStatus := func() {
		c.updateState()
		raw, err := json.Marshal(c.status)
		if err == nil {
			err = atomicWrite(statusPath, raw)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "cannot write controller status:", err)
		}
	}
	for {
		raw, err := readUserFile(filepath.Join(dataRoot, "control-request.json"), uid, maxRequestSize)
		if err == nil && string(raw) != string(lastRequest) {
			lastRequest = append([]byte(nil), raw...)
			var req request
			if err = decodeStrict(raw, &req); err != nil {
				c.recoveryError = false
				c.status.Error = "invalid request: " + err.Error()
			} else if req.ID != c.status.ID || string(req.Settings) != string(c.status.Settings) || c.status.Error != "" {
				c.apply(req)
			}
			writeStatus()
		} else if err != nil && !os.IsNotExist(err) {
			c.recoveryError = false
			c.status.Error = "cannot read request: " + err.Error()
			writeStatus()
		}
		if c.recover() {
			writeStatus()
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
