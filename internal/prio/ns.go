//go:build linux
// +build linux

package prio

import (
	"fmt"

	"github.com/vishvananda/netns"
)

// EnsureNamespace returns a handle to the namespace, creating it if missing.
func EnsureNamespace(name string) (netns.NsHandle, error) {
	nsHandle, err := netns.GetFromName(name)
	if err != nil {
		if _, errCreate := netns.NewNamed(name); errCreate != nil {
			return 0, fmt.Errorf("create netns %s: %w", name, errCreate)
		}
		nsHandle, err = netns.GetFromName(name)
		if err != nil {
			return 0, fmt.Errorf("get netns %s after create: %w", name, err)
		}
	}
	return nsHandle, nil
}

// InNamespaceByName opens the named netns, runs fn inside it, and restores the original namespace.
func InNamespaceByName(name string, fn func() error) error {
	nsHandle, err := netns.GetFromName(name)
	if err != nil {
		return err
	}
	defer nsHandle.Close()
	return inNamespace(nsHandle, fn)
}

// inNamespace switches to the given netns, runs fn, and switches back.
func inNamespace(ns netns.NsHandle, fn func() error) error {
	orig, err := netns.Get()
	if err != nil {
		return fmt.Errorf("get current netns: %w", err)
	}
	defer orig.Close()

	if err := netns.Set(ns); err != nil {
		return fmt.Errorf("set netns: %w", err)
	}
	defer netns.Set(orig)

	return fn()
}
