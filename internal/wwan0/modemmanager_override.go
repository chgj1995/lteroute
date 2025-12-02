//go:build linux
// +build linux

package wwan0

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// InstallModemManagerOverride writes a systemd drop-in so ModemManager runs
// inside the given netns and the system D-Bus socket is visible there.
func InstallModemManagerOverride(namespace string) error {
	if strings.TrimSpace(namespace) == "" {
		return fmt.Errorf("namespace must be provided")
	}

	if err := runSudo("mkdir", "-p", "/etc/systemd/system/ModemManager.service.d"); err != nil {
		return err
	}

	override := fmt.Sprintf(`[Service]
NetworkNamespacePath=/var/run/netns/%s
BindReadOnlyPaths=/run/dbus/system_bus_socket
ExecStartPre=/bin/bash -lc 'for i in {1..20}; do ip netns list | grep -q "^%s\\b" && exit 0; sleep 0.5; done; echo "%s not ready"; exit 1'
`, namespace, namespace, namespace)

	cmd := exec.Command("sudo", "tee", "/etc/systemd/system/ModemManager.service.d/override.conf")
	cmd.Stdin = strings.NewReader(override)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return err
	}

	if err := runSudo("systemctl", "daemon-reload"); err != nil {
		return err
	}
	_ = runSudo("systemctl", "restart", "ModemManager")
	return nil
}

// RemoveModemManagerOverride deletes the drop-in and restarts ModemManager (best effort).
func RemoveModemManagerOverride() {
	_ = runSudo("rm", "-f", "/etc/systemd/system/ModemManager.service.d/override.conf")
	_ = runSudo("systemctl", "daemon-reload")
	_ = runSudo("systemctl", "restart", "ModemManager")
}

func runSudo(args ...string) error {
	cmd := exec.Command("sudo", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
