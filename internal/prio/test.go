//go:build linux
// +build linux

package prio

import (
	"fmt"
	"os/exec"
	"strings"
)

// PingFromNamespace runs a connectivity check from the given namespace/interface.
// It does not create or delete any resources; it only issues a ping.
func PingFromNamespace(ns, iface, dst string) error {
	args := []string{"netns", "exec", ns, "ping", "-I", iface, "-c", "3", dst}
	cmd := exec.Command("ip", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ping %s via %s in %s: %w (%s)", dst, iface, ns, err, strings.TrimSpace(string(out)))
	}
	return nil
}
