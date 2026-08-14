# Remote Rig

Remote control of a Kenwood TS-590S transceiver: a Go server speaks CAT over a
serial link, a macOS SwiftUI client steers the rig over a network.

## Language

**Rig**:
The TS-590S transceiver being operated remotely.
_Avoid_: radio, transceiver

**VFO**:
A tunable frequency register on the rig; the rig has two (VFO A, VFO B). The
active VFO is the one the front end receives on; switching it via CAT (`FR`)
also drives the S-meter and mode.
_Avoid_: channel, slot

**Mode**:
The emission type currently selected (LSB, USB, CW, FM, AM, FSK, CW-R, USER).
_Avoid_: bandwidth

**TX / RX**:
Transmit and receive — the two states of the rig's front end. TX is engaged
via PTT.
_Avoid_: sending, receiving

**PTT**:
Push-to-talk; the momentary action that puts the rig into TX. A latched TX
locks the rig in TX without holding the key.
_Avoid_: talk, mic key

**Band**:
The amateur band a frequency falls in (e.g. 40 m), derived from the VFO
frequency.
_Avoid_: segment, allocation

**S-meter**:
The rig's received-signal-strength meter, reported as an integer.
_Avoid_: RSSI, signal bar

**Frequency readout**:
The displayed value of the active VFO, readable to 1 Hz.
_Avoid_: dial, display

**Step**:
The tuning increment applied by a nudge (1/10/100/1000 Hz).
_Avoid_: increment, granularity

**Levels**:
The operator-adjustable settings RF, PWR, SQL, and AF, each an integer 0–255.
_Avoid_: gains, knobs
