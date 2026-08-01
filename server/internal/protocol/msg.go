package protocol

// Message is the JSON control message exchanged over the TCP channel.
// Each message has a type in T and only the relevant fields are populated.
type Message struct {
	T string `json:"t"`

	// auth
	Token string `json:"token,omitempty"`

	// cat passthrough
	Cmd string `json:"cmd,omitempty"`

	// generic response / event payload
	Raw  string `json:"raw,omitempty"`
	State *RadioState `json:"state,omitempty"`

	// audio control
	Action  string      `json:"action,omitempty"`
	Opus    *OpusParams `json:"opus,omitempty"`
	Status  string      `json:"status,omitempty"`
	Dir     string      `json:"dir,omitempty"`
	Adjusted bool      `json:"adjusted,omitempty"`

	// ptt
	On *bool `json:"on,omitempty"`

	// state request flag
	StateReq bool `json:"state_req,omitempty"`

	// audio_params (effective, clamped)
	SampleRate int `json:"sampleRate,omitempty"`
	Channels   int `json:"channels,omitempty"`
	FrameMs    int `json:"frameMs,omitempty"`
	Bitrate    int `json:"bitrate,omitempty"`

	// error
	Msg string `json:"msg,omitempty"`
}

// OpusParams describes the negotiated Opus configuration.
type OpusParams struct {
	SampleRate int `json:"sampleRate"`
	Channels   int `json:"channels"`
	FrameMs    int `json:"frameMs"`
	Bitrate    int `json:"bitrate"`
}

// RadioState is a snapshot of the rig used for the `state` message.
type RadioState struct {
	FreqA   int64  `json:"freqA"`
	FreqB   int64  `json:"freqB"`
	Mode    string `json:"mode"`
	PTT     bool   `json:"ptt"`
	AF       int    `json:"af"`
	RF       int    `json:"rf"`
	Power    int    `json:"power"`
	SQL      int    `json:"sql"`
	SMeter   int    `json:"smeter"`
	AudioOn  bool   `json:"audioOn"`
	RxPaused bool   `json:"rxPaused"`
	PowerOn  bool   `json:"powerOn"`
}

// Builders ---------------------------------------------------------------

func MsgAuthOK() Message       { return Message{T: "auth_ok"} }
func MsgAuthFail() Message      { return Message{T: "auth_fail"} }
func MsgError(msg string) Message { return Message{T: "error", Msg: msg} }

func MsgCatResp(raw string) Message    { return Message{T: "cat_resp", Raw: raw} }
func MsgCatEvent(raw string) Message   { return Message{T: "cat_event", Raw: raw} }

func MsgState(s *RadioState) Message { return Message{T: "state", State: s} }

func MsgAudioStatus(status string) Message { return Message{T: "audio", Status: status} }

func MsgAudioRxStatus(status string) Message {
	return Message{T: "audio_rx", Status: status}
}

func MsgAudioParams(p *OpusParams, adjusted bool) Message {
	return Message{
		T:        "audio_params",
		SampleRate: p.SampleRate,
		Channels:   p.Channels,
		FrameMs:    p.FrameMs,
		Bitrate:    p.Bitrate,
		Adjusted:   adjusted,
	}
}

func MsgPTTAck(on bool) Message { return Message{T: "ptt_ack", On: &on} }
