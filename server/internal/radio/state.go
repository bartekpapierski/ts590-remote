package radio

import (
	"strings"

	"github.com/bartek/ts590-remote/server/internal/protocol"
)

// GetState snapshots the rig's main parameters for the `state` message.
func (r *Radio) GetState() *protocol.RigState {
	s := &protocol.RigState{PTT: r.ptt.Load()}
	if f, err := r.GetFreqVFOA(); err == nil {
		s.FreqA = f
	}
	if f, err := r.GetFreqVFOB(); err == nil {
		s.FreqB = f
	}
	if m, err := r.GetMode(); err == nil {
		s.Mode = m
	}
	if v, err := r.GetAF(); err == nil {
		s.AF = v
	}
	if v, err := r.GetRF(); err == nil {
		s.RF = v
	}
	if v, err := r.GetPower(); err == nil {
		s.Power = v
	}
	if v, err := r.GetSQL(); err == nil {
		s.SQL = v
	}
	if v, err := r.GetSMeter(); err == nil {
		s.SMeter = v
	}
	if resp, err := r.Send("PS;"); err == nil {
		s.PowerOn = strings.HasPrefix(resp, "PS1")
	}
	return s
}
