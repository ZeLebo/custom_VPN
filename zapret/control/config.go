package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"regexp"
	"strings"
)

const maxRequestSize = 512 * 1024

type site struct {
	Host  string `json:"host"`
	Exact bool   `json:"exact"`
	Route string `json:"route"`
}

type portRange struct {
	First int `json:"first"`
	Last  int `json:"last"`
}

type settings struct {
	Enabled        bool        `json:"enabled"`
	Strategy       string      `json:"strategy"`
	IPSet          string      `json:"ipset"`
	Sites          []site      `json:"sites"`
	CustomHosts    []string    `json:"customHosts"`
	UDPBypassPorts []portRange `json:"udpBypassPorts"`
	VPNServers     []string    `json:"vpnServers"`
}

type request struct {
	Version  int             `json:"version"`
	ID       string          `json:"id"`
	Settings json.RawMessage `json:"settings"`
}

type status struct {
	Version  int             `json:"version"`
	ID       string          `json:"id"`
	State    string          `json:"state"`
	Settings json.RawMessage `json:"settings"`
	Error    string          `json:"error"`
}

var strategyPattern = regexp.MustCompile(`^general(-[a-z0-9]+)*$`)
var requestIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,80}$`)
var hostLabelPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`)

func decodeStrict(data []byte, value any) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(value); err != nil {
		return err
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("unexpected trailing JSON")
	}
	return nil
}

func validHost(host string) bool {
	if len(host) > 253 || !strings.Contains(host, ".") {
		return false
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) > 63 || !hostLabelPattern.MatchString(label) {
			return false
		}
	}
	return true
}

func parseSettings(raw json.RawMessage) (settings, error) {
	var s settings
	if err := decodeStrict(raw, &s); err != nil {
		return s, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return s, err
	}
	for _, key := range []string{"enabled", "strategy", "ipset", "sites", "customHosts", "udpBypassPorts", "vpnServers"} {
		if data, ok := fields[key]; !ok || bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
			return s, fmt.Errorf("missing setting %s", key)
		}
	}
	if !strategyPattern.MatchString(s.Strategy) {
		return s, fmt.Errorf("invalid strategy")
	}
	if s.IPSet != "none" && s.IPSet != "any" && s.IPSet != "loaded" {
		return s, fmt.Errorf("invalid IPSet mode")
	}
	if len(s.Sites) > 1024 || len(s.CustomHosts) > 1024 || len(s.UDPBypassPorts) > 128 || len(s.VPNServers) > 4096 {
		return s, fmt.Errorf("too many settings")
	}
	for _, entry := range s.Sites {
		if !validHost(entry.Host) {
			return s, fmt.Errorf("invalid site hostname")
		}
		switch entry.Route {
		case "direct", "vpn", "block", "zapret":
		default:
			return s, fmt.Errorf("invalid site route")
		}
	}
	for _, host := range s.CustomHosts {
		if !validHost(host) {
			return s, fmt.Errorf("invalid custom hostname")
		}
		found := false
		for _, entry := range s.Sites {
			if entry.Host == host && entry.Route == "zapret" {
				found = true
			}
		}
		if !found {
			return s, fmt.Errorf("custom hostname has no Zapret route")
		}
	}
	for _, port := range s.UDPBypassPorts {
		if port.First < 1 || port.Last < port.First || port.Last > 65535 {
			return s, fmt.Errorf("invalid UDP port range")
		}
	}
	for _, address := range s.VPNServers {
		ip, err := netip.ParseAddr(address)
		if err != nil || !ip.Is4() {
			return s, fmt.Errorf("invalid VPN server IPv4 address")
		}
	}
	return s, nil
}

func renderStrategy(original string, s settings) (string, error) {
	var prefix []string
	for _, entry := range s.Sites {
		if entry.Route == "zapret" {
			continue
		}
		host := entry.Host
		if entry.Exact {
			host = "^" + host
		}
		lines := []string{"--filter-tcp=1-65535", "--filter-udp=1-65535", "--hostlist-domains=" + host}
		var exceptions []string
		for _, other := range s.Sites {
			if other.Route == "zapret" && strings.HasSuffix(other.Host, "."+entry.Host) {
				host := other.Host
				if other.Exact {
					host = "^" + host
				}
				exceptions = append(exceptions, host)
			}
		}
		if len(exceptions) > 0 {
			lines = append(lines, "--hostlist-exclude-domains="+strings.Join(exceptions, ","))
		}
		prefix = append(prefix, strings.Join(append(lines, "--new"), "\n"))
	}
	for _, port := range s.UDPBypassPorts {
		prefix = append(prefix, fmt.Sprintf("--filter-udp=%d-%d\n--new", port.First, port.Last))
	}
	if len(s.CustomHosts) > 0 {
		count := 0
		for _, block := range regexp.MustCompile(`(?m)^--new\s*$`).Split(original, -1) {
			if !strings.Contains(block, "/list-general-user.txt") {
				continue
			}
			var lines []string
			for _, line := range strings.Split(block, "\n") {
				if strings.TrimSpace(line) != "" && !strings.HasPrefix(line, "--hostlist") && !strings.HasPrefix(line, "--ipset") {
					lines = append(lines, line)
				}
			}
			lines = append(lines, "--hostlist-domains="+strings.Join(s.CustomHosts, ","), "--new")
			prefix = append(prefix, strings.Join(lines, "\n"))
			count++
		}
		if count == 0 {
			return "", fmt.Errorf("strategy has no general HTTP/TLS and QUIC profiles")
		}
	}
	if len(prefix) == 0 {
		return original, nil
	}
	return strings.Join(prefix, "\n") + "\n" + original, nil
}
