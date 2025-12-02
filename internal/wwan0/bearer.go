//go:build linux
// +build linux

package wwan0

import (
	"net"
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

func readBearer(cli mmcliClient, path string) (bearerDetails, error) {
	var b bearerDetails
	out, err := cli.output("-b", path)
	if err != nil {
		return b, err
	}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		// mmcli output sometimes prefixes fields like "IPv4 configuration | address:"
		if strings.Contains(line, "|") {
			parts := strings.SplitN(line, "|", 2)
			if len(parts) == 2 {
				line = strings.TrimSpace(parts[1])
			}
		}
		lower := strings.ToLower(line)
		switch {
		case strings.HasPrefix(lower, "interface:"):
			b.Interface = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
		case strings.HasPrefix(lower, "ipv4 configuration"):
			// skip header
		case strings.HasPrefix(lower, "address:"):
			ipStr := strings.TrimSpace(strings.TrimPrefix(line, "address:"))
			if ip := net.ParseIP(ipStr); ip != nil {
				b.Addrs = append(b.Addrs, net.IPNet{IP: ip})
			}
		case strings.HasPrefix(lower, "prefix:"):
			pfxStr := strings.TrimSpace(strings.TrimPrefix(line, "prefix:"))
			if len(b.Addrs) > 0 {
				if ip := b.Addrs[len(b.Addrs)-1].IP; ip != nil {
					if bits, err := strconv.Atoi(pfxStr); err == nil {
						if mask := net.CIDRMask(bits, 8*len(ip)); mask != nil {
							b.Addrs[len(b.Addrs)-1] = net.IPNet{IP: ip, Mask: mask}
						}
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
