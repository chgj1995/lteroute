//go:build linux
// +build linux

package wwan0

import (
	"fmt"
	"os/exec"
)

// RunWWAN0Integration은 main의 "test --wwan0" 요청으로 실행되는 실장 장비 테스트 엔트리다.
// DefaultConfig만 사용한다.
func RunWWAN0Integration() error {
	cfg := DefaultConfig()
	fmt.Printf("[wwan0 test] starting with cfg: apn=%s ipType=%s iface=%s modemWait(retries=%d,interval=%s) connectWait(retries=%d,interval=%s)\n",
		cfg.APN, cfg.IPType, cfg.Interface, cfg.ModemWaitRetries, cfg.ModemWaitInterval, cfg.ConnectWaitRetries, cfg.ConnectWaitInterval)

	info, err := ConnectAndConfigure(cfg)
	if err != nil {
		return fmt.Errorf("[wwan0 test] FAILED: %w", err)
	}

	fmt.Printf("[wwan0 test] SUCCESS iface=%s addrs=%v gw=%v mtu=%d dns=%v\n", info.Interface, info.Addrs, info.Gateway, info.MTU, info.DNS)
	if err := pingConnectivity(info, cfg.Namespace); err != nil {
		return err
	}
	fmt.Println("[wwan0 test] connectivity check (ping 8.8.8.8) succeeded")
	return nil
}

func pingConnectivity(info Info, namespace string) error {
	dst := "8.8.8.8"
	ipCmd := func(args ...string) *exec.Cmd {
		if namespace != "" {
			all := append([]string{"netns", "exec", namespace}, args...)
			return exec.Command("ip", all...)
		}
		return exec.Command("ip", args...)
	}
	pingCmd := func(args ...string) *exec.Cmd {
		if namespace != "" {
			all := append([]string{"netns", "exec", namespace, "ping"}, args...)
			return exec.Command("ip", all...)
		}
		return exec.Command("ping", args...)
	}

	fmt.Printf("[wwan0 test] pinging %s via %s (ns=%s)\n", dst, info.Interface, namespace)
	_ = ipCmd("route", "add", dst+"/32", "via", info.Gateway.String(), "dev", info.Interface).Run()
	defer ipCmd("route", "del", dst+"/32", "via", info.Gateway.String(), "dev", info.Interface).Run()

	cmd := pingCmd("-I", info.Interface, "-c", "3", dst)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ping %s via %s failed: %w (%s)", dst, info.Interface, err, string(out))
	}
	return nil
}
