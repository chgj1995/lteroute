//go:build linux
// +build linux

package ntpns

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type Config struct {
	Namespace   string
	Server      string
	ServicePath string
	TimerPath   string
	NtpdatePath string
}

func DefaultConfig() Config {
	return Config{
		Namespace:   "prio_ns",
		Server:      "ntp.ubuntu.com",
		ServicePath: "/etc/systemd/system/ntpdate-in-ns.service",
		TimerPath:   "/etc/systemd/system/ntpdate-in-ns.timer",
		NtpdatePath: "/usr/sbin/ntpdate",
	}
}

// Install writes the service/timer to run ntpdate inside the namespace and enables the timer.
func Install(cfg Config) error {
	if err := writeService(cfg); err != nil {
		return err
	}
	if err := writeTimer(cfg); err != nil {
		return err
	}
	if err := run("sudo", "systemctl", "daemon-reload"); err != nil {
		return err
	}
	_ = run("sudo", "systemctl", "enable", "--now", "ntpdate-in-ns.timer")
	return nil
}

// Uninstall removes the ntp service/timer and reloads systemd.
func Uninstall(cfg Config) error {
	_ = run("sudo", "systemctl", "disable", "--now", "ntpdate-in-ns.timer")
	_ = run("sudo", "rm", "-f", cfg.ServicePath, cfg.TimerPath)
	_ = run("sudo", "systemctl", "daemon-reload")
	return nil
}

func writeService(cfg Config) error {
	content := fmt.Sprintf(`[Unit]
Description=Time synchronization using ntpdate in %s
After=prio-ns-autoswitch.service
Wants=prio-ns-autoswitch.service

[Service]
Type=oneshot
ExecStart=/bin/ip netns exec %s %s -4 -s %s
`, cfg.Namespace, cfg.Namespace, cfg.NtpdatePath, cfg.Server)

	return tee(cfg.ServicePath, content)
}

func writeTimer(cfg Config) error {
	content := `[Unit]
Description=Run ntpdate-in-ns.service hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
`
	return tee(cfg.TimerPath, content)
}

func tee(path, content string) error {
	cmd := exec.Command("sudo", "tee", path)
	cmd.Stdin = strings.NewReader(content)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
