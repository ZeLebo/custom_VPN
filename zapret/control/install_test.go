package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestInstallerProducesExactControllerArguments(t *testing.T) {
	installer, err := os.ReadFile("../payload/install.sh")
	if err != nil {
		t.Fatal(err)
	}
	// Run the real plist edits without installing or restarting a system service.
	var commands []string
	for _, line := range strings.Split(string(installer), "\n") {
		if strings.HasPrefix(line, "/usr/bin/plutil ") {
			commands = append(commands, line)
		}
	}
	if len(commands) == 0 {
		t.Fatal("installer has no plist configuration commands")
	}
	template, err := os.ReadFile("../payload/io.github.flowseal.zapretmac.plist.in")
	if err != nil {
		t.Fatal(err)
	}
	for _, dataRoot := range []string{
		"/Users/test/Library/Application Support/ZapretMac",
		"/Users/A & B <'\"test>/Library/Application Support/ZapretMac",
	} {
		t.Run(dataRoot, func(t *testing.T) {
			plist := filepath.Join(t.TempDir(), "service.plist")
			if err := os.WriteFile(plist, template, 0600); err != nil {
				t.Fatal(err)
			}
			for attempt := 0; attempt < 2; attempt++ {
				cmd := exec.Command("/bin/sh", "-eu", "-c", strings.Join(commands, "\n"))
				cmd.Env = append(os.Environ(), "PLIST="+plist, "DATA_ROOT="+dataRoot, "USER_ID=501")
				if output, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("configure plist: %v: %s", err, output)
				}
				raw, err := exec.Command("/usr/bin/plutil", "-extract", "ProgramArguments", "json", "-o", "-", plist).Output()
				if err != nil {
					t.Fatal(err)
				}
				var args []string
				if err := json.Unmarshal(raw, &args); err != nil {
					t.Fatal(err)
				}
				want := []string{installedBase + "/bin/zapret-control", "-data-root", dataRoot, "-uid", "501"}
				if !reflect.DeepEqual(args, want) {
					t.Fatalf("invalid controller arguments: got %q, want %q", args, want)
				}
			}
		})
	}
}
