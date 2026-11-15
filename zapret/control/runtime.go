package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var listNames = []string{"list-general.txt", "list-general-user.txt", "list-google.txt", "list-exclude.txt", "list-exclude-user.txt", "ipset-all.txt", "ipset-exclude.txt", "ipset-exclude-user.txt"}

// The helper reads data owned by the installing user, never executable scripts
// or arbitrary paths supplied in a request. NOFOLLOW also covers replacement races.
func readUserFile(path string, uid uint32, limit int64) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uid || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, fmt.Errorf("unexpected owner, type or size: %s", filepath.Base(path))
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("file too large: %s", filepath.Base(path))
	}
	return data, err
}

func atomicWrite(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".control-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Chmod(0644)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(f.Name(), path)
	}
	return err
}

type runtime struct {
	base, dataRoot string
	uid            uint32
	process        *exec.Cmd
	done           chan error
	exited         bool
	start          func() error
	stop           func() error
	validate       func(string) error
}

func newRuntime(base, dataRoot string, uid uint32) *runtime {
	r := &runtime{base: base, dataRoot: dataRoot, uid: uid}
	r.start, r.stop, r.validate = r.startEngine, r.stopEngine, r.validateConfig
	return r
}

func (r *runtime) prepare(s settings) (string, error) {
	original, err := os.ReadFile(filepath.Join(r.base, "strategies", s.Strategy+".conf.in"))
	if err != nil {
		return "", err
	}
	rendered, err := renderStrategy(string(original), s)
	if err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp(r.base, ".candidate-")
	if err != nil {
		return "", err
	}
	complete := false
	defer func() {
		if !complete {
			os.RemoveAll(dir)
		}
	}()
	if err = os.Mkdir(filepath.Join(dir, "lists"), 0755); err != nil {
		return "", err
	}
	for _, name := range listNames {
		data, err := readUserFile(filepath.Join(r.dataRoot, "lists", name), r.uid, 16*1024*1024)
		if err != nil {
			return "", err
		}
		if err = os.WriteFile(filepath.Join(dir, "lists", name), data, 0644); err != nil {
			return "", err
		}
	}
	for name, value := range map[string]string{
		"selected-strategy": s.Strategy + "\n", "ipset-mode": s.IPSet + "\n",
		"vpn-servers.txt": strings.Join(s.VPNServers, "\n") + "\n", "strategy.conf.in": rendered,
	} {
		if err = os.WriteFile(filepath.Join(dir, name), []byte(value), 0644); err != nil {
			return "", err
		}
	}
	ipset := filepath.Join(r.base, "ipset-none.txt")
	if s.IPSet == "any" {
		ipset = filepath.Join(r.base, "ipset-any.txt")
	} else if s.IPSet == "loaded" {
		ipset = filepath.Join(dir, "lists", "ipset-all.txt")
	}
	check := strings.NewReplacer("@BASE@", r.base, "@LISTS@", filepath.Join(dir, "lists"), "@IPSET@", ipset).Replace(rendered)
	path := filepath.Join(dir, "check.conf")
	if err = os.WriteFile(path, []byte("--dry-run\n"+check), 0600); err != nil {
		return "", err
	}
	// utunws reopens lists after dropping root, including during --dry-run.
	if err = os.Chmod(dir, 0755); err != nil {
		return "", err
	}
	if err = r.validate(path); err != nil {
		return "", err
	}
	os.Remove(path)
	complete = true
	return dir, nil
}

func (r *runtime) validateConfig(path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, filepath.Join(r.base, "bin", "utunws"), "@"+path).CombinedOutput()
	if err != nil {
		if len(out) > 2000 {
			out = out[len(out)-2000:]
		}
		return fmt.Errorf("invalid engine config: %w: %s", err, out)
	}
	return nil
}

func (r *runtime) Apply(s settings) error {
	if !s.Enabled {
		return r.stop()
	}
	candidate, err := r.prepare(s)
	if err != nil {
		return err
	}
	defer os.RemoveAll(candidate)
	current, previous := filepath.Join(r.base, "runtime"), filepath.Join(r.base, "runtime.previous")
	if err = os.RemoveAll(previous); err != nil {
		return err
	}
	wasRunning := r.Running()
	if err = r.stop(); err != nil {
		return err
	}
	hadPrevious := false
	if _, err = os.Stat(current); err == nil {
		if err = os.Rename(current, previous); err != nil {
			return err
		}
		hadPrevious = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if err = os.Rename(candidate, current); err == nil && s.Enabled {
		err = r.start()
	}
	if err != nil {
		_ = r.stop()
		_ = os.RemoveAll(current)
		if hadPrevious {
			if restoreErr := os.Rename(previous, current); restoreErr != nil {
				return fmt.Errorf("apply failed: %v; restore failed: %w", err, restoreErr)
			}
			if wasRunning {
				if restoreErr := r.start(); restoreErr != nil {
					return fmt.Errorf("apply failed: %v; engine restore failed: %w", err, restoreErr)
				}
			}
		}
		return err
	}
	if err := os.RemoveAll(previous); err != nil {
		fmt.Fprintln(os.Stderr, "cannot remove previous snapshot:", err)
	}
	return nil
}

func (r *runtime) Running() bool {
	if r.process == nil || r.exited {
		return false
	}
	select {
	case <-r.done:
		r.exited = true
		return false
	default:
		return true
	}
}

func (r *runtime) startEngine() error {
	if r.Running() {
		return fmt.Errorf("engine is already running")
	}
	if r.process != nil {
		if err := r.stopEngine(); err != nil {
			return err
		}
	}
	log, err := os.OpenFile(filepath.Join(r.base, "zapret.log"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := exec.Command("/bin/sh", filepath.Join(r.base, "run.sh"), filepath.Join(r.base, "runtime"))
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "ZAPRET_CONTROLLER_PID=" + strconv.Itoa(os.Getpid())}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout, cmd.Stderr = log, log
	if err = cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	r.process, r.done = cmd, done
	r.exited = false
	go func() { done <- cmd.Wait() }()
	deadline := time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		if !r.Running() {
			return fmt.Errorf("engine exited before becoming ready; see zapret.log")
		}
		if err = exec.Command("/sbin/ifconfig", "utun50").Run(); err == nil {
			out, checkErr := exec.Command("/sbin/pfctl", "-a", "com.apple/zapret-macos", "-sr").Output()
			if checkErr == nil && strings.Contains(string(out), "route-to") {
				return nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = r.stopEngine()
	return fmt.Errorf("engine did not become ready within 12 seconds")
}

func (r *runtime) stopEngine() error {
	if r.process == nil {
		return nil
	}
	_ = r.Running()
	group := -r.process.Process.Pid
	if err := syscall.Kill(group, syscall.SIGTERM); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	if !r.exited {
		select {
		case <-r.done:
		case <-time.After(4 * time.Second):
			_ = syscall.Kill(group, syscall.SIGKILL)
			<-r.done
		}
	}
	// The shell may have died before its engine/watchdog children. Retain and
	// clean the whole owned group before another instance can install PF rules.
	_ = syscall.Kill(group, syscall.SIGKILL)
	r.process = nil
	r.exited = false
	if err := exec.Command("/bin/sh", filepath.Join(r.base, "cleanup.sh")).Run(); err != nil {
		return fmt.Errorf("engine cleanup failed: %w", err)
	}
	return nil
}

func (r *runtime) Restart() error { return r.start() }
