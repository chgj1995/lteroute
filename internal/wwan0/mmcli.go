//go:build linux
// +build linux

//
package wwan0

import (
	"fmt"
	"os/exec"
	"strings"
)

func ensureConnected(modemPath, apn, ipType string) error {
	state, err := modemState(modemPath)
	if err != nil {
		return err
	}
	if strings.Contains(state, "connected") {
		return nil
	}

	args := []string{"-m", modemPath, "--simple-connect=apn=" + apn}
	if ipType != "" {
		args[len(args)-1] = args[len(args)-1] + ",ip-type=" + ipType
	}
	if err := runCmd("mmcli", args...); err != nil {
		return fmt.Errorf("simple-connect: %w", err)
	}
	return nil
}

func modemState(modemPath string) (string, error) {
	out, err := exec.Command("mmcli", "-m", modemPath).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("mmcli -m %s: %w (%s)", modemPath, err, strings.TrimSpace(string(out)))
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "state:") || strings.Contains(line, "state:") {
			return line, nil
		}
	}
	return "", nil
}

func findModem() (string, error) {
	out, err := exec.Command("mmcli", "-L").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("mmcli -L: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "/org/freedesktop/ModemManager1/Modem/") {
			parts := strings.Fields(line)
			if len(parts) > 0 {
				return parts[0], nil
			}
		}
	}
	return "", fmt.Errorf("no modem found in mmcli -L")
}

func pickDataBearer(modemPath string) (string, error) {
	out, err := exec.Command("mmcli", "-m", modemPath).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("mmcli -m %s: %w (%s)", modemPath, err, strings.TrimSpace(string(out)))
	}
	var bearerPath string
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "/org/freedesktop/ModemManager1/Bearer/") {
			fields := strings.Fields(line)
			for _, f := range fields {
				if strings.Contains(f, "/org/freedesktop/ModemManager1/Bearer/") {
					bearerPath = f
					break
				}
			}
			if bearerPath != "" {
				break
			}
		}
	}
	if bearerPath == "" {
		return "", fmt.Errorf("no bearer found for modem %s", modemPath)
	}
	return bearerPath, nil
}

func runCmd(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w (%s)", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}
