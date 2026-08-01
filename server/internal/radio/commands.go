package radio

import (
	"errors"
	"strconv"
	"strings"
)

// Mode code tables for the TS-590S MD command.
var modeToString = map[int]string{
	0: "LSB", 1: "USB", 2: "CW", 3: "FM",
	4: "AM", 5: "FSK", 6: "CW-R", 7: "USER",
}
var stringToMode = func() map[string]int {
	m := map[string]int{}
	for k, v := range modeToString {
		m[v] = k
	}
	return m
}()

// Raw is the generic CAT passthrough (satisfies "all commands").
func (r *Radio) Raw(cmd string) (string, error) { return r.Send(cmd) }

// Identify returns the rig ID; TS-590S answers "ID020;".
func (r *Radio) Identify() (string, error) { return r.Send("ID;") }

// Power turns the rig supply on/off.
func (r *Radio) Power(on bool) error {
	if on {
		_, err := r.Send("PS1;")
		return err
	}
	_, err := r.Send("PS0;")
	return err
}

func (r *Radio) SetFreqVFOA(hz int64) error {
	_, err := r.Send("FA" + freqStr(hz) + ";")
	return err
}
func (r *Radio) GetFreqVFOA() (int64, error) {
	resp, err := r.Send("FA;")
	if err != nil {
		return 0, err
	}
	return parseFreq(resp)
}

func (r *Radio) SetFreqVFOB(hz int64) error {
	_, err := r.Send("FB" + freqStr(hz) + ";")
	return err
}
func (r *Radio) GetFreqVFOB() (int64, error) {
	resp, err := r.Send("FB;")
	if err != nil {
		return 0, err
	}
	return parseFreq(resp)
}

// SetMode accepts a mode label (USB, CW, ...) or a single digit.
func (r *Radio) SetMode(mode string) error {
	code, ok := stringToMode[strings.ToUpper(mode)]
	if !ok {
		if len(mode) == 1 && mode[0] >= '0' && mode[0] <= '9' {
			code = int(mode[0] - '0')
		} else {
			return errors.New("radio: unknown mode " + mode)
		}
	}
	_, err := r.Send("MD" + strconv.Itoa(code) + ";")
	return err
}
func (r *Radio) GetMode() (string, error) {
	resp, err := r.Send("MD;")
	if err != nil {
		return "", err
	}
	d, ok := digitsAfter(resp, 2)
	if !ok {
		return "", errors.New("radio: bad mode response")
	}
	if s, ok := modeToString[d]; ok {
		return s, nil
	}
	return strconv.Itoa(d), nil
}

// SetPTT keys the transmitter (TX) or returns to receive (RX).
func (r *Radio) SetPTT(on bool) error {
	var resp string
	var err error
	if on {
		resp, err = r.Send("TX;")
	} else {
		resp, err = r.Send("RX;")
	}
	if err == nil {
		// TS-590S confirms TX with "TX;" / "RX;" echo.
		_ = resp
		r.ptt.Store(on)
	}
	return err
}

// Level controls (0-255 unless noted).
func (r *Radio) SetAF(level int) error { return r.setInt("AG", level) }
func (r *Radio) GetAF() (int, error)       { return r.getInt("AG;") }
func (r *Radio) SetRF(level int) error { return r.setInt("RG", level) }
func (r *Radio) GetRF() (int, error)       { return r.getInt("RG;") }
func (r *Radio) SetPower(level int) error { return r.setInt("PC", level) }
func (r *Radio) GetPower() (int, error)     { return r.getInt("PC;") }
func (r *Radio) SetSQL(level int) error { return r.setInt("SQ", level) }
func (r *Radio) GetSQL() (int, error)      { return r.getInt("SQ;") }

// GetSMeter reads the S-meter (SM0).
func (r *Radio) GetSMeter() (int, error) {
	resp, err := r.Send("SM0;")
	if err != nil {
		return 0, err
	}
	d, _ := digitsAfter(resp, 3)
	return d, nil
}

// --- helpers ----------------------------------------------------------

func (r *Radio) setInt(cmd string, level int) error {
	if level < 0 {
		level = 0
	}
	if level > 255 {
		level = 255
	}
	_, err := r.Send(cmd + pad3(level) + ";")
	return err
}
func (r *Radio) getInt(cmd string) (int, error) {
	resp, err := r.Send(cmd)
	if err != nil {
		return 0, err
	}
	d, _ := digitsAfter(resp, 2)
	return d, nil
}

func freqStr(hz int64) string {
	if hz < 0 {
		hz = 0
	}
	s := strconv.FormatInt(hz, 10)
	for len(s) < 11 {
		s = "0" + s
	}
	if len(s) > 11 {
		s = s[len(s)-11:]
	}
	return s
}
func pad3(v int) string {
	s := strconv.Itoa(v)
	for len(s) < 3 {
		s = "0" + s
	}
	return s
}
func digitsAfter(s string, skip int) (int, bool) {
	s = strings.TrimSuffix(s, ";")
	if len(s) <= skip {
		return 0, false
	}
	var b strings.Builder
	for _, c := range s[skip:] {
		if c >= '0' && c <= '9' {
			b.WriteByte(byte(c))
		}
	}
	if b.Len() == 0 {
		return 0, false
	}
	v, err := strconv.Atoi(b.String())
	if err != nil {
		return 0, false
	}
	return v, true
}
func parseFreq(s string) (int64, error) {
	s = strings.TrimSuffix(s, ";")
	if len(s) < 2 {
		return 0, errors.New("radio: bad frequency response")
	}
	var b strings.Builder
	for _, c := range s[2:] {
		if c >= '0' && c <= '9' {
			b.WriteByte(byte(c))
		}
	}
	if b.Len() == 0 {
		return 0, errors.New("radio: no frequency digits")
	}
	return strconv.ParseInt(b.String(), 10, 64)
}
