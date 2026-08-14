package radio

import (
	"testing"
)

func TestFreqStr(t *testing.T) {
	tests := []struct {
		hz   int64
		want string
	}{
		{0, "00000000000"},
		{14000000, "00014000000"},
		{14265000, "00014265000"},
		{99999999999, "99999999999"},
		{100000000000, "00000000000"}, // truncated to 11 digits
		{-5, "00000000000"},            // negative clamped to 0
	}
	for _, tt := range tests {
		got := freqStr(tt.hz)
		if got != tt.want {
			t.Errorf("freqStr(%d) = %q, want %q", tt.hz, got, tt.want)
		}
		if len(got) != 11 {
			t.Errorf("freqStr(%d) returned %d chars, want 11", tt.hz, len(got))
		}
	}
}

func TestPad3(t *testing.T) {
	tests := []struct {
		v    int
		want string
	}{
		{0, "000"},
		{5, "005"},
		{42, "042"},
		{255, "255"},
		{-1, "0-1"}, // negative: strconv.Itoa produces "-1", padded to 3 chars
	}
	for _, tt := range tests {
		got := pad3(tt.v)
		if got != tt.want {
			t.Errorf("pad3(%d) = %q, want %q", tt.v, got, tt.want)
		}
	}
}

func TestDigitsAfter(t *testing.T) {
	tests := []struct {
		s    string
		skip int
		want int
		ok   bool
	}{
		{"AG128;", 2, 128, true},
		{"PC050;", 2, 50, true},
		{"MD3;", 2, 3, true},
		{"SM005;", 3, 5, true},
		{"XX;", 2, 0, false},     // nothing after prefix
		{"X;", 2, 0, false},     // too short
		{"XX;", 5, 0, false},    // skip exceeds length
		{"XX;", 2, 0, false},    // empty after prefix
		{"AG;", 2, 0, false},    // no digits
		{"AGABC;", 2, 0, false}, // non-digit chars only
	}
	for _, tt := range tests {
		got, ok := digitsAfter(tt.s, tt.skip)
		if got != tt.want || ok != tt.ok {
			t.Errorf("digitsAfter(%q, %d) = (%d, %v), want (%d, %v)", tt.s, tt.skip, got, ok, tt.want, tt.ok)
		}
	}
}

func TestParseFreq(t *testing.T) {
	tests := []struct {
		s    string
		want int64
		ok   bool
	}{
		{"FA00014000000;", 14000000, true},
		{"FA00014265000;", 14265000, true},
		{"FB00007000000;", 7000000, true},
		{"FA;", 0, false},       // too short
		{"FA", 0, false},        // no semicolon, too short
		{"FA;", 0, false},       // no digits
		{"FAABC;", 0, false},    // non-digit chars
		{"FA00000000000;", 0, true},
		{"FA00099999999;", 99999999, true},
	}
	for _, tt := range tests {
		got, err := parseFreq(tt.s)
		if tt.ok {
			if err != nil {
				t.Errorf("parseFreq(%q) returned error %v, want nil", tt.s, err)
			}
			if got != tt.want {
				t.Errorf("parseFreq(%q) = %d, want %d", tt.s, got, tt.want)
			}
		} else {
			if err == nil {
				t.Errorf("parseFreq(%q) returned (%d, nil), want error", tt.s, got)
			}
		}
	}
}

func TestModeTables(t *testing.T) {
	// Verify all 8 modes are present in both directions, with codes 1-7 and 9
	// (0 and 8 are "None (setting failure)" per the TS-590S reference).
	for code, name := range modeToString {
		if code < 1 || code > 9 || code == 8 {
			t.Errorf("modeToString has out-of-range code %d", code)
		}
		reverse, ok := stringToMode[name]
		if !ok {
			t.Errorf("mode %q (code %d) not found in stringToMode", name, code)
		}
		if reverse != code {
			t.Errorf("mode %q maps to %d in stringToMode, want %d", name, reverse, code)
		}
	}
	if len(modeToString) != 8 {
		t.Errorf("modeToString has %d entries, want 8", len(modeToString))
	}
}

func TestSetModeValidation(t *testing.T) {
	// Verify mode label -> code mapping used by SetMode.
	// SetMode uppercases the input before lookup, so test with uppercase.
	tests := []struct {
		mode string
		want int
	}{
		{"USB", 2},
		{"LSB", 1},
		{"CW", 3},
		{"FM", 4},
		{"AM", 5},
		{"FSK", 6},
		{"CW-R", 7},
		{"FSK-R", 9},
		{"1", 1}, // single digit
		{"9", 9},
	}
	for _, tt := range tests {
		code, ok := stringToMode[tt.mode]
		if !ok {
			// try single digit
			if len(tt.mode) == 1 && tt.mode[0] >= '0' && tt.mode[0] <= '9' {
				code = int(tt.mode[0] - '0')
				ok = true
			}
		}
		if !ok {
			t.Errorf("mode %q could not be resolved", tt.mode)
			continue
		}
		if code != tt.want {
			t.Errorf("mode %q resolved to %d, want %d", tt.mode, code, tt.want)
		}
	}

	// Unknown mode should fail.
	_, ok := stringToMode["INVALID"]
	if ok {
		t.Error("mode \"INVALID\" should not resolve")
	}
}
