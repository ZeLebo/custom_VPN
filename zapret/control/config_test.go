package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sampleSettings() settings {
	return settings{Enabled: true, Strategy: "general-simple-fake", IPSet: "none",
		Sites: []site{}, CustomHosts: []string{}, UDPBypassPorts: []portRange{}, VPNServers: []string{}}
}

func rawSettings(s settings) json.RawMessage {
	raw, _ := json.Marshal(s)
	return raw
}

func TestRejectUnsafeSettings(t *testing.T) {
	cases := []struct {
		name string
		edit func(*settings)
	}{
		{"strategy path", func(s *settings) { s.Strategy = "../../tmp/script" }},
		{"IPSet", func(s *settings) { s.IPSet = "unknown" }},
		{"host injection", func(s *settings) { s.Sites = []site{{Host: "test.com\n--debug=@/etc/test", Route: "direct"}} }},
		{"route", func(s *settings) { s.Sites = []site{{Host: "test.com", Route: "typo"}} }},
		{"custom route", func(s *settings) { s.CustomHosts = []string{"test.com"} }},
		{"port", func(s *settings) { s.UDPBypassPorts = []portRange{{First: 1, Last: 99999}} }},
		{"IPv4", func(s *settings) { s.VPNServers = []string{"1.1.1.1\n--new"} }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := sampleSettings()
			tc.edit(&s)
			if _, err := parseSettings(rawSettings(s)); err == nil {
				t.Fatal("unsafe setting accepted")
			}
		})
	}
	if _, err := parseSettings([]byte(`{"enabled":false,"strategy":"general","ipset":"none"}`)); err == nil {
		t.Fatal("incomplete configuration accepted")
	}
	if err := decodeStrict([]byte(`{} {}`), new(request)); err == nil {
		t.Fatal("trailing JSON accepted")
	}
}

func TestSpecificSiteExceptions(t *testing.T) {
	s := sampleSettings()
	s.Sites = []site{{Host: "private.sub.example.com", Route: "direct"}, {Host: "sub.example.com", Route: "zapret"}, {Host: "example.com", Route: "direct"}}
	s.CustomHosts = []string{"sub.example.com"}
	original, err := os.ReadFile("../payload/strategies/general-simple-fake.conf.in")
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := renderStrategy(string(original), s)
	if err != nil {
		t.Fatal(err)
	}
	blocks := strings.Split(rendered, "--new")
	if !strings.Contains(blocks[0], "--hostlist-domains=private.sub.example.com") ||
		!strings.Contains(blocks[1], "--hostlist-exclude-domains=sub.example.com") {
		t.Fatal("more specific exception lost priority")
	}
	count := 0
	for _, block := range blocks {
		if strings.Contains(block, "--hostlist-domains=sub.example.com") {
			count++
			if strings.Contains(block, "--ipset") || strings.Contains(block, "--hostlist-exclude") {
				t.Fatal("custom site incorrectly depends on old list filters")
			}
		}
	}
	if count != 2 || !strings.HasSuffix(rendered, string(original)) {
		t.Fatal("selected strategy was not preserved")
	}
}

func TestAllBundledStrategies(t *testing.T) {
	files, err := filepath.Glob("../payload/strategies/*.conf.in")
	if err != nil || len(files) != 21 {
		t.Fatalf("unexpected strategies: %v %v", files, err)
	}
	s := sampleSettings()
	s.Sites = []site{{Host: "example.com", Route: "zapret"}, {Host: "exact.example.net", Exact: true, Route: "direct"}}
	s.CustomHosts = []string{"example.com"}
	s.UDPBypassPorts = []portRange{{First: 50000, Last: 50100}}
	for _, file := range files {
		t.Run(filepath.Base(file), func(t *testing.T) {
			original, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			rendered, err := renderStrategy(string(original), s)
			if err != nil || !strings.HasSuffix(rendered, string(original)) || !strings.Contains(rendered, "--hostlist-domains=^exact.example.net") {
				t.Fatalf("invalid rendered strategy: %v", err)
			}
		})
	}
}
