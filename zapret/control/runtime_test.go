package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func testRuntime(t *testing.T) *runtime {
	t.Helper()
	base, data := t.TempDir(), t.TempDir()
	for _, dir := range []string{filepath.Join(base, "strategies"), filepath.Join(data, "lists")} {
		if err := os.Mkdir(dir, 0755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range listNames {
		if err := os.WriteFile(filepath.Join(data, "lists", name), nil, 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(base, "strategies", "general-simple-fake.conf.in"), []byte("--filter-tcp=443\n"), 0644); err != nil {
		t.Fatal(err)
	}
	r := newRuntime(base, data, uint32(os.Getuid()))
	if err := os.WriteFile(filepath.Join(base, "cleanup.sh"), []byte("#!/bin/sh\nexit 0\n"), 0644); err != nil {
		t.Fatal(err)
	}
	r.validate = func(string) error { return nil }
	r.start, r.stop = func() error { return nil }, func() error { return nil }
	return r
}

func TestExitedSupervisorRetainsItsProcessGroupUntilCleanup(t *testing.T) {
	r := testRuntime(t)
	cmd := exec.Command("/bin/sh", "-c", "sleep 10 & wait")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) })
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	r.process, r.done = cmd, done
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for r.Running() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if r.process == nil {
		t.Fatal("lost the process group before cleaning up orphaned engine children")
	}
	if err := r.stopEngine(); err != nil || r.process != nil {
		t.Fatalf("cannot clean an exited supervisor: %v", err)
	}
}

func TestPrepareRejectsSymlinksOwnersAndOversizedFiles(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "source")
	if err := os.WriteFile(file, []byte("content"), 0644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	uid := uint32(os.Getuid())
	for _, tc := range []struct {
		path  string
		uid   uint32
		limit int64
	}{{link, uid, 100}, {file, uid + 1, 100}, {file, uid, 2}, {dir, uid, 100}} {
		if _, err := readUserFile(tc.path, tc.uid, tc.limit); err == nil {
			t.Fatalf("unsafe file accepted: %+v", tc)
		}
	}
}

func TestFailedValidationDoesNotStopRunningEngine(t *testing.T) {
	r := testRuntime(t)
	stopped := false
	r.stop = func() error { stopped = true; return nil }
	r.validate = func(string) error { return errors.New("bad generated config") }
	if err := r.Apply(sampleSettings()); err == nil || stopped {
		t.Fatal("invalid candidate affected the existing engine")
	}
}

func TestPreparedListsAreReadableAfterEngineDropsRoot(t *testing.T) {
	r := testRuntime(t)
	r.validate = func(config string) error {
		candidate := filepath.Dir(config)
		for _, dir := range []string{candidate, filepath.Join(candidate, "lists")} {
			info, err := os.Stat(dir)
			if err != nil {
				return err
			}
			if info.Mode().Perm()&0001 == 0 || info.Mode().Perm()&0022 != 0 {
				return fmt.Errorf("engine cannot safely traverse snapshot after dropping root: %s mode %04o", dir, info.Mode().Perm())
			}
		}
		for _, name := range listNames {
			info, err := os.Stat(filepath.Join(candidate, "lists", name))
			if err != nil {
				return err
			}
			if info.Mode().Perm()&0004 == 0 || info.Mode().Perm()&0022 != 0 {
				return fmt.Errorf("engine cannot safely read list after dropping root: %s mode %04o", name, info.Mode().Perm())
			}
		}
		return nil
	}
	candidate, err := r.prepare(sampleSettings())
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(candidate)
}

func TestValidationErrorRetainsFinalDiagnostic(t *testing.T) {
	r := testRuntime(t)
	if err := os.Mkdir(filepath.Join(r.base, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	engine := "#!/bin/sh\nprintf '%4096s\\nfile_open_test: Permission denied\\n' ''\nexit 1\n"
	if err := os.WriteFile(filepath.Join(r.base, "bin", "utunws"), []byte(engine), 0755); err != nil {
		t.Fatal(err)
	}
	err := r.validateConfig("unused.conf")
	if err == nil || !strings.Contains(err.Error(), "file_open_test: Permission denied") {
		t.Fatalf("lost the failure behind startup output: %v", err)
	}
}

func TestFailedStartRestoresPreviousSnapshot(t *testing.T) {
	r := testRuntime(t)
	current := filepath.Join(r.base, "runtime")
	if err := os.Mkdir(current, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(current, "old-config"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	r.start = func() error { return errors.New("engine could not start") }
	if err := r.Apply(sampleSettings()); err == nil {
		t.Fatal("failed start reported success")
	}
	if data, err := os.ReadFile(filepath.Join(current, "old-config")); err != nil || string(data) != "keep" {
		t.Fatalf("previous snapshot was not restored: %v", err)
	}
}

func TestStopDoesNotRequireRevalidatingStrategyFiles(t *testing.T) {
	r := testRuntime(t)
	s := sampleSettings()
	s.Enabled = false
	s.Strategy = "general-missing"
	stopped := false
	r.stop = func() error { stopped = true; return nil }
	if err := r.Apply(s); err != nil || !stopped {
		t.Fatalf("cannot stop while a saved strategy is unavailable: %v", err)
	}
}

func TestFailedStartRestartsPreviouslyRunningEngine(t *testing.T) {
	r := testRuntime(t)
	current := filepath.Join(r.base, "runtime")
	if err := os.Mkdir(current, 0700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/sleep", "10")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	r.process, r.done = cmd, done
	r.stop = r.stopEngine
	t.Cleanup(func() { _ = r.stopEngine() })
	starts := 0
	r.start = func() error {
		starts++
		if starts == 1 {
			return errors.New("new engine failed")
		}
		return nil
	}
	if err := r.Apply(sampleSettings()); err == nil || starts != 2 {
		t.Fatalf("old running engine was not restarted: starts=%d error=%v", starts, err)
	}
}

func TestNativeEngineAcceptsPreparedSnapshot(t *testing.T) {
	engine, err := filepath.Abs("../nfq/utunws")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(engine); os.IsNotExist(err) {
		t.Skip("build zapret/nfq/utunws to run the native config parser check")
	}
	r := testRuntime(t)
	if err := os.Mkdir(filepath.Join(r.base, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(engine, filepath.Join(r.base, "bin", "utunws")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ipset-none.txt", "ipset-any.txt"} {
		if err := os.WriteFile(filepath.Join(r.base, name), nil, 0644); err != nil {
			t.Fatal(err)
		}
	}
	r.validate = r.validateConfig
	s := sampleSettings()
	s.Sites = []site{{Host: "new-deaf.one", Route: "direct"}}
	candidate, err := r.prepare(s)
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(candidate)
	data, err := os.ReadFile(filepath.Join(candidate, "strategy.conf.in"))
	if err != nil || !strings.Contains(string(data), "--hostlist-domains=new-deaf.one") {
		t.Fatal("direct exception missing from prepared config")
	}
}

func TestNativeEngineAcceptsEveryBundledStrategy(t *testing.T) {
	engine, err := filepath.Abs("../nfq/utunws")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(engine); os.IsNotExist(err) {
		t.Skip("build zapret/nfq/utunws to run native parser checks")
	}
	r := testRuntime(t)
	if err := os.Mkdir(filepath.Join(r.base, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(engine, filepath.Join(r.base, "bin", "utunws")); err != nil {
		t.Fatal(err)
	}
	copyFile := func(source, dest string) {
		t.Helper()
		data, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dest, data, 0644); err != nil {
			t.Fatal(err)
		}
	}
	assets, _ := filepath.Glob("../payload/bin/*.bin")
	for _, asset := range assets {
		copyFile(asset, filepath.Join(r.base, "bin", filepath.Base(asset)))
	}
	for _, name := range []string{"ipset-none.txt", "ipset-any.txt"} {
		copyFile("../payload/"+name, filepath.Join(r.base, name))
	}
	for _, name := range listNames {
		copyFile("../payload/default-lists/"+name, filepath.Join(r.dataRoot, "lists", name))
	}
	s := sampleSettings()
	s.Sites = []site{{Host: "private.sub.example.com", Route: "direct"}, {Host: "sub.example.com", Route: "zapret"}, {Host: "example.com", Route: "direct"}}
	s.CustomHosts = []string{"sub.example.com"}
	s.UDPBypassPorts = []portRange{{First: 50000, Last: 50100}}
	r.validate = r.validateConfig
	files, _ := filepath.Glob("../payload/strategies/*.conf.in")
	for _, file := range files {
		copyFile(file, filepath.Join(r.base, "strategies", filepath.Base(file)))
		s.Strategy = strings.TrimSuffix(filepath.Base(file), ".conf.in")
		for _, mode := range []string{"none", "any", "loaded"} {
			t.Run(s.Strategy+"/"+mode, func(t *testing.T) {
				s.IPSet = mode
				candidate, err := r.prepare(s)
				if err != nil {
					t.Fatal(err)
				}
				os.RemoveAll(candidate)
			})
		}
	}
}
