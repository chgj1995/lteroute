//go:build linux
// +build linux

//
package wwan0

// ConnectAndConfigure ensures the modem is connected via mmcli, parses bearer IPv4
// details, and applies IP/MTU to the interface in the root namespace.
// 기본 라우팅은 호출자가 별도로 구성해야 한다.
func ConnectAndConfigure(cfg Config) (Info, error) {
	var info Info
	modemPath, err := findModem()
	if err != nil {
		return info, err
	}

	if err := ensureConnected(modemPath, cfg.APN, cfg.IPType); err != nil {
		return info, err
	}

	bearerPath, err := pickDataBearer(modemPath)
	if err != nil {
		return info, err
	}

	bearer, err := readBearer(bearerPath)
	if err != nil {
		return info, err
	}

	if bearer.Interface == "" {
		bearer.Interface = cfg.Interface
	}

	if err := applyInterfaceConfig(bearer.Interface, bearer); err != nil {
		return info, err
	}

	info.Interface = bearer.Interface
	info.MTU = bearer.MTU
	info.Gateway = bearer.Gateway
	info.DNS = bearer.DNS
	info.Addrs = bearer.Addrs
	return info, nil
}
