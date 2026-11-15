package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestStrategyProbesDoNotWaitForRunningEngine(t *testing.T) {
	raw, err := os.ReadFile("../payload/test-strategies.sh")
	if err != nil {
		t.Fatal(err)
	}
	script := string(raw)
	start := strings.Index(script, "    INDEX=0\n")
	if start < 0 {
		t.Fatal("cannot find strategy probe scheduling block")
	}
	end := strings.Index(script[start:], "    if cancel_requested; then CANCELLED=1; break; fi\n    SCORE=0")
	if end < 0 {
		t.Fatal("cannot find strategy probe scheduling block")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "available-1"), []byte("1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "selected-1"), []byte("0\t0.01\t192.0.2.1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	harness := `
set -eu
/bin/sleep 30 &
RUN_PID=$!
trap 'kill "$RUN_PID" 2>/dev/null || true; wait "$RUN_PID" 2>/dev/null || true' EXIT
TARGETS=example.com
TLS13=$TEST_TLS13
TAB=$(printf '\t')
RESULT_DIR=$TMP
ping_test() { /bin/sleep 0.05; printf 'ping\n' >"$2"; }
curl_test() { /bin/sleep 0.05; printf '%s\n' "$1" >"$4"; }
` + script[start:start+end] + `
test -s "$RESULT_DIR/1-ping"
test -s "$RESULT_DIR/1-http"
test -s "$RESULT_DIR/1-tls12"
if [ "$TLS13" -eq 1 ]; then test -s "$RESULT_DIR/1-tls13"; fi
kill -0 "$RUN_PID"
`
	for _, tls13 := range []string{"0", "1"} {
		t.Run("TLS13="+tls13, func(t *testing.T) {
			cmd := exec.Command("/bin/sh", "-c", harness)
			cmd.Env = append(os.Environ(), "TMP="+dir, "TEST_TLS13="+tls13)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(2 * time.Second):
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				<-done
				t.Fatal("strategy probes are waiting for the long-running engine; cancellation and controller restoration cannot run")
			}
		})
	}
}

func TestTerminatingStrategyTestRestoresControllerAndExits(t *testing.T) {
	raw, err := os.ReadFile("../payload/test-strategies.sh")
	if err != nil {
		t.Fatal(err)
	}
	script := string(raw)
	start := strings.Index(script, "stop_strategy() {")
	if start < 0 {
		t.Fatal("cannot find strategy restoration function")
	}
	end := strings.Index(script[start:], "\nrun_user() {")
	if end < 0 {
		t.Fatal("cannot find strategy restoration traps")
	}
	dir := t.TempDir()
	for _, name := range []string{"data", "payload", "work"} {
		if err := os.Mkdir(filepath.Join(dir, name), 0755); err != nil {
			t.Fatal(err)
		}
	}
	install := "#!/bin/sh\nprintf 'restored\\n' >>\"$2/restored\"\n"
	if err := os.WriteFile(filepath.Join(dir, "payload", "install.sh"), []byte(install), 0755); err != nil {
		t.Fatal(err)
	}
	stop := "#!/bin/sh\n/bin/kill -KILL \"$(/bin/cat \"$DATA_ROOT/engine-pid\")\"\n"
	if err := os.WriteFile(filepath.Join(dir, "payload", "stop.sh"), []byte(stop), 0755); err != nil {
		t.Fatal(err)
	}
	harness := `
set -u
REPORT=$DATA_ROOT/report
PROGRESS=$DATA_ROOT/progress
CANCEL=$DATA_ROOT/cancel
ORIGINAL_STRATEGY=general-alt4
ORIGINAL_IPSET=none
RUN_PID=
set_progress() { printf '%s\n' "$1" >"$PROGRESS"; }
: >"$REPORT"
: >"$CANCEL"
` + script[start:start+end] + `
/bin/sh -c 'trap "" TERM; printf "ready\n" >"$DATA_ROOT/engine-ready"; while :; do /bin/sleep 1; done' &
RUN_PID=$!
printf '%s\n' "$RUN_PID" >"$DATA_ROOT/engine-pid"
while [ ! -s "$DATA_ROOT/engine-ready" ]; do /bin/sleep 0.01; done
printf 'ready\n' >"$DATA_ROOT/ready"
wait "$RUN_PID"
printf 'continued\n' >"$DATA_ROOT/continued"
`
	cmd := exec.Command("/bin/sh", "-c", harness)
	data := filepath.Join(dir, "data")
	cmd.Env = append(os.Environ(), "DATA_ROOT="+data, "SOURCE="+filepath.Join(dir, "payload"), "TMP="+filepath.Join(dir, "work"),
		"TEST_UID="+strconv.Itoa(os.Getuid()), "TEST_GID="+strconv.Itoa(os.Getgid()))
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(filepath.Join(data, "ready")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-done
			t.Fatal("test runner did not become ready")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		t.Fatal("strategy cancellation did not finish")
	}
	if _, err := os.Stat(filepath.Join(data, "continued")); err == nil {
		t.Fatal("strategy test continued after cancellation and controller restoration")
	}
	restored, err := os.ReadFile(filepath.Join(data, "restored"))
	if err != nil || string(restored) != "restored\n" {
		t.Fatalf("controller was not restored exactly once: %q %v", restored, err)
	}
	for name, want := range map[string]string{"selected-strategy": "general-alt4\n", "ipset-mode": "none\n"} {
		got, err := os.ReadFile(filepath.Join(data, name))
		if err != nil || string(got) != want {
			t.Fatalf("original %s not restored: %q %v", name, got, err)
		}
	}
}
