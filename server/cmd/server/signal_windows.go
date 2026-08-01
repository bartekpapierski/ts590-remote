//go:build windows

package main

import "os"

func extraSignals() []os.Signal {
	return nil
}
