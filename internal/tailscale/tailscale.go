//go:build linux
// +build linux

package tailscale

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

type Config struct {
	Namespace  string
	StatePath  string
	SocketPath string
	Port       string
	Flags      string
}

func DefaultConfig() Config {
	return Config{
		Namespace:  "prio_ns",
		StatePath:  "/var/lib/tailscale/tailscaled.state",
		SocketPath: "/run/tailscale/tailscaled.sock",
		Port:       "", // default
		Flags:      "",
	}
}

// Install installs tailscale (apt if missing), writes override to run in the
// target netns, and reloads/restarts tailscaled.
func Install(cfg Config) error {
	if err := ensureTailscalePackage(); err != nil {
		return err
	}
	if err := ensureDefaultEnv(); err != nil {
		return err
	}
	if err := writeOverride(cfg); err != nil {
		return err
	}
	if err := reloadRestart(); err != nil {
		return err
	}
	return nil
}

// ConfigureRouting ensures tailscale0 is up inside the target netns and
// optionally disables host-side MagicDNS and restores a static host resolv.conf.
func ConfigureRouting(cfg Config) error {
	if err := waitTailscale0(cfg.Namespace, 10, 1*time.Second); err != nil {
		return err
	}
	// Disable MagicDNS in host netns (best effort)
	_ = run("sudo", "tailscale", "set", "--accept-dns=false")
	// Restore host resolv.conf (best effort)
	restoreHostDNS()
	return nil
}

// Remove cleans persistent overrides and leaves package untouched.
func Remove(cfg Config) error {
	_ = run("sudo", "systemctl", "disable", "--now", "tailscaled")
	_ = run("sudo", "rm", "-f", "/etc/systemd/system/tailscaled.service.d/override.conf")
	_ = run("sudo", "rm", "-f", "/etc/default/tailscaled")
	_ = run("sudo", "systemctl", "daemon-reload")
	return nil
}

func waitTailscale0(ns string, retries int, interval time.Duration) error {
	for i := 0; i < retries; i++ {
		if checkLinkInNS(ns, "tailscale0") {
			return nil
		}
		time.Sleep(interval)
	}
	return fmt.Errorf("tailscale0 not visible in %s after %d attempts", ns, retries)
}

func checkLinkInNS(ns, link string) bool {
	cmd := exec.Command("ip", "netns", "exec", ns, "ip", "link", "show", link)
	return cmd.Run() == nil
}

func restoreHostDNS() {
	content := "nameserver 8.8.8.8\nnameserver 1.1.1.1\n"
	cmd := exec.Command("sudo", "tee", "/etc/resolv.conf")
	cmd.Stdin = strings.NewReader(content)
	_ = cmd.Run()
}

func ensureTailscalePackage() error {
	if _, err := exec.LookPath("tailscaled"); err == nil {
		return nil
	}
	// best-effort apt install (deb-based, current use case).
	if err := run("sudo", "apt-get", "update", "-y"); err != nil {
		return err
	}
	if err := run("sudo", "apt-get", "install", "-y", "tailscale"); err != nil {
		return err
	}
	return nil
}

func ensureDefaultEnv() error {
	content := "# Environment for tailscaled (sourced by systemd unit)\n# PORT=41641\n# FLAGS=\n"
	cmd := exec.Command("sudo", "tee", "/etc/default/tailscaled")
	cmd.Stdin = strings.NewReader(content)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func writeOverride(cfg Config) error {
	if err := run("sudo", "mkdir", "-p", "/etc/systemd/system/tailscaled.service.d"); err != nil {
		return err
	}
	override := fmt.Sprintf(`[Unit]
After=turn-on-lte.service prio-ns-autoswitch.service
Requires=prio-ns-autoswitch.service

[Service]
EnvironmentFile=/etc/default/tailscaled
ExecStartPre=/bin/bash -lc 'for i in {1..20}; do ip netns list | grep -q "^%s\\b" && exit 0; sleep 0.5; done; echo "%s not ready"; exit 1'
ExecStart=
ExecStart=/bin/ip netns exec %s /usr/sbin/tailscaled --state=%s --socket=%s %s %s
ExecStopPost=
ExecStopPost=/bin/ip netns exec %s /usr/sbin/tailscaled --cleanup
`, cfg.Namespace, cfg.Namespace, cfg.Namespace, cfg.StatePath, cfg.SocketPath, portFlag(cfg.Port), cfg.Flags, cfg.Namespace)

	cmd := exec.Command("sudo", "tee", "/etc/systemd/system/tailscaled.service.d/override.conf")
	cmd.Stdin = strings.NewReader(override)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func portFlag(port string) string {
	if strings.TrimSpace(port) == "" {
		return ""
	}
	return "--port=" + strings.TrimSpace(port)
}

func reloadRestart() error {
	if err := run("sudo", "systemctl", "daemon-reload"); err != nil {
		return err
	}
	_ = run("sudo", "systemctl", "enable", "--now", "tailscaled")
	_ = run("sudo", "systemctl", "restart", "tailscaled")
	return nil
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
