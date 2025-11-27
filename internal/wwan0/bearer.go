//go:build linux
// +build linux

//
package wwan0

import (
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"
)

// bearerDetails holds parsed mmcli bearer fields we care about.
type bearerDetails struct {
	Interface string
	Addrs     []net.IPNet
	Gateway   net.IP
	MTU       int
	DNS       []net.IP
}

func readBearer(path string) (bearerDetails, error) {
	var b bearerDetails
	out, err := exec.Command("mmcli", "-b", path).CombinedOutput()
	if err != nil {
		return b, fmt.Errorf("mmcli -b %s: %w (%s)", path, err, strings.TrimSpace(string(out)))
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		lower := strings.ToLower(line)
		switch {
		case strings.HasPrefix(lower, "interface:"):
			b.Interface = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
		case strings.HasPrefix(lower, "ipv4 configuration"):
			// skip header
		case strings.HasPrefix(lower, "address:"):
			ipStr := strings.TrimSpace(strings.TrimPrefix(line, "address:"))
			// prefix parsed later
			b.Addrs = append(b.Addrs, net.IPNet{IP: net.ParseIP(ipStr)})
		case strings.HasPrefix(lower, "prefix:"):
			pfxStr := strings.TrimSpace(strings.TrimPrefix(line, "prefix:"))
			if len(b.Addrs) > 0 {
				if ip := b.Addrs[len(b.Addrs)-1].IP; ip != nil {
					_, pfx, _ := net.ParseCIDR(fmt.Sprintf("%s/%s", ip.String(), pfxStr))
					if pfx != nil {
						b.Addrs[len(b.Addrs)-1] = *pfx
					}
				}
			}
		case strings.HasPrefix(lower, "gateway:"):
			ip := net.ParseIP(strings.TrimSpace(strings.TrimPrefix(line, "gateway:")))
			if ip != nil {
				b.Gateway = ip
			}
		case strings.HasPrefix(lower, "mtu:"):
			mtuStr := strings.TrimSpace(strings.TrimPrefix(line, "mtu:"))
			if val, err := strconv.Atoi(mtuStr); err == nil {
				b.MTU = val
			}
		case strings.HasPrefix(lower, "dns:"):
			raw := strings.TrimSpace(strings.TrimPrefix(line, "dns:"))
			raw = strings.ReplaceAll(raw, ",", " ")
			fields := strings.Fields(raw)
			for _, f := range fields {
				if ip := net.ParseIP(f); ip != nil {
					b.DNS = append(b.DNS, ip)
				}
			}
		}
	}
	return b, nil
}
