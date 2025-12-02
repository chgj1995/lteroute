//go:build linux
// +build linux

package wwan0

import (
	"fmt"
	"os/exec"
	"strings"
	"time"
)

type mmcliClient struct {
	namespace string
}

func newMMCLIClient(cfg Config) mmcliClient {
	return mmcliClient{namespace: cfg.Namespace}
}

func ensureConnected(cli mmcliClient, modemPath, apn, ipType string) error {
	state, err := modemState(cli, modemPath)
	if err != nil {
		return err
	}
	if state == "connected" {
		return nil
	}

	args := []string{"-m", modemPath, "--simple-connect=apn=" + apn}
	if ipType != "" {
		args[len(args)-1] = args[len(args)-1] + ",ip-type=" + ipType
	}
	if _, err := cli.output(args...); err != nil {
		return fmt.Errorf("simple-connect: %w", err)
	}
	return nil
}

func modemState(cli mmcliClient, modemPath string) (string, error) {
	out, err := cli.output("-m", modemPath)
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "state:") {
			parts := strings.SplitN(line, "state:", 2)
			if len(parts) != 2 {
				continue
			}
			state := strings.TrimSpace(parts[1])
			if fields := strings.Fields(state); len(fields) > 0 {
				return fields[0], nil
			}
			return state, nil
		}
	}
	return "", fmt.Errorf("state not found in mmcli -m %s output", modemPath)
}

func findModem(cli mmcliClient) (string, error) {
	out, err := cli.output("-L")
	if err != nil {
		return "", err
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

func findModemWithWait(cli mmcliClient, cfg Config) (string, error) {
	for i := 0; i < cfg.ModemWaitRetries; i++ {
		fmt.Printf("[wwan0] waiting for modem (attempt %d/%d)...\n", i+1, cfg.ModemWaitRetries)
		if path, err := findModem(cli); err == nil {
			fmt.Printf("[wwan0] modem detected: %s\n", path)
			return path, nil
		}
		time.Sleep(cfg.ModemWaitInterval)
	}
	return "", fmt.Errorf("no modem found after %d retries", cfg.ModemWaitRetries)
}

func pickDataBearer(cli mmcliClient, modemPath string, cfg Config) (string, error) {
	fmt.Printf("[wwan0] querying bearer for modem %s\n", modemPath)
	for i := 0; i < cfg.ConnectWaitRetries; i++ {
		out, err := cli.output("-m", modemPath)
		if err != nil {
			fmt.Printf("[wwan0] mmcli -m error (attempt %d/%d): %v\n", i+1, cfg.ConnectWaitRetries, err)
			time.Sleep(cfg.ConnectWaitInterval)
			continue
		}
		paths := extractBearerPaths(string(out))
		if len(paths) == 0 {
			fmt.Printf("[wwan0] no bearer paths yet (attempt %d/%d)\n", i+1, cfg.ConnectWaitRetries)
		}
		if len(paths) > 0 {
			p := paths[len(paths)-1] // use the last bearer from mmcli output
			b, berr := readBearer(cli, p)
			if berr != nil {
				fmt.Printf("[wwan0] read bearer %s failed: %v\n", p, berr)
				time.Sleep(cfg.ConnectWaitInterval)
				continue
			}
			fmt.Printf("[wwan0] bearer %s addr=%v gw=%v mtu=%d\n", p, b.Addrs, b.Gateway, b.MTU)
			if hasIPv4Config(b) {
				fmt.Printf("[wwan0] selected bearer %s with IPv4 config\n", p)
				return p, nil
			}
		}
		fmt.Printf("[wwan0] waiting for bearer with IPv4 config (attempt %d/%d)...\n", i+1, cfg.ConnectWaitRetries)
		time.Sleep(cfg.ConnectWaitInterval)
	}
	return "", fmt.Errorf("no bearer with IPv4 config found for modem %s after %d retries", modemPath, cfg.ConnectWaitRetries)
}

func waitBearerConfig(cli mmcliClient, bearerPath string, cfg Config) (bearerDetails, error) {
	var b bearerDetails
	var lastErr error
	for i := 0; i < cfg.ConnectWaitRetries; i++ {
		var err error
		b, err = readBearer(cli, bearerPath)
		if err != nil {
			lastErr = err
			fmt.Printf("[wwan0] read bearer %s error (attempt %d/%d): %v\n", bearerPath, i+1, cfg.ConnectWaitRetries, err)
			time.Sleep(cfg.ConnectWaitInterval)
			continue
		}
		if b.Gateway != nil && len(b.Addrs) > 0 {
			return b, nil
		}
		fmt.Printf("[wwan0] waiting for bearer IPv4 config (attempt %d/%d)...\n", i+1, cfg.ConnectWaitRetries)
		time.Sleep(cfg.ConnectWaitInterval)
	}
	if lastErr != nil {
		return b, fmt.Errorf("bearer %s read failed after %d retries: %w", bearerPath, cfg.ConnectWaitRetries, lastErr)
	}
	return b, fmt.Errorf("bearer %s missing IPv4 config after %d retries", bearerPath, cfg.ConnectWaitRetries)
}

func extractBearerPaths(out string) []string {
	var paths []string
	lines := strings.Split(out, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "/org/freedesktop/ModemManager1/Bearer/") {
			fields := strings.Fields(line)
			for _, f := range fields {
				if strings.Contains(f, "/org/freedesktop/ModemManager1/Bearer/") {
					paths = append(paths, f)
				}
			}
		}
	}
	return paths
}

func hasIPv4Config(b bearerDetails) bool {
	return b.Gateway != nil && len(b.Addrs) > 0
}

func (c mmcliClient) output(args ...string) ([]byte, error) {
	display := "mmcli " + strings.Join(args, " ")
	var cmd *exec.Cmd
	if strings.TrimSpace(c.namespace) != "" {
		display = fmt.Sprintf("ip netns exec %s %s", c.namespace, display)
		allArgs := append([]string{"netns", "exec", c.namespace, "mmcli"}, args...)
		cmd = exec.Command("ip", allArgs...)
	} else {
		cmd = exec.Command("mmcli", args...)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s: %w (%s)", display, err, strings.TrimSpace(string(out)))
	}
	return out, nil
}
