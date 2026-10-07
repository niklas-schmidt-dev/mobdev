package main

// Live view: a viewer watches a device's screen and, if it may, taps and types on it.
//
// A viewer opens a WebSocket at /v1/live?device=<id>&fps=<1-10> (or /h/<mac>/v1/live) with the
// Mac's client key: "Authorization: Bearer mdc_…" or, from a browser, the subprotocols
// "mobdev-live" and "mobdev-auth.mdc_…"; the relay answers with "mobdev-live". The relay asks the
// Mac to stream the device ({"type":"live_start"}) and passes the Mac's frames
// ({"type":"live_frame"}) to every viewer of that device: one stream per Mac and device, however
// many watch. A viewer acknowledges each frame it showed ({"type":"ack","seq"}); one with
// liveMaxUnacked frames unacknowledged gets none until it catches up, so a slow viewer misses
// frames instead of piling them up. A viewer's input ({"type":"input","action",…}) reaches the Mac
// as {"type":"live_input"}, which the Mac runs as a tool call. The hosted relay
// (cloud/relay/src/live.ts) speaks the same protocol and also takes the dashboard's tickets.

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/coder/websocket"
)

const (
	liveSubprotocol = "mobdev-live"
	liveAuthPrefix  = "mobdev-auth."
	liveDefaultFPS  = 5
	liveMaxFPS      = 10
	// liveMaxUnacked is how many frames a viewer may have unacknowledged; newer frames skip it.
	liveMaxUnacked = 2
	// liveMaxViewers is how many viewers one Mac may have, across its devices.
	liveMaxViewers = 10
	// liveMaxInputs is how many inputs a viewer may send per second; more are refused.
	liveMaxInputs = 10
	// liveMaxFrameBytes drops larger frames from a Mac instead of passing them to browsers.
	liveMaxFrameBytes = 2 << 20
	liveMaxText       = 1000
	liveMaxDevice     = 200
	liveMaxKey        = 16
)

// Close codes for viewers. The hosted relay uses the same, and also 4004 (the link expired),
// 4005 (the link was revoked) and 4029 (the account's allowance is used up).
const (
	closeLiveMacGone websocket.StatusCode = 4002 // the Mac disconnected
	closeLiveEnded   websocket.StatusCode = 4003 // the Mac ended the stream; the live_end before says why
	closeLiveTimeout websocket.StatusCode = 4008 // nothing from the viewer, not even "ping", for IdleTimeout
)

type liveStream struct {
	id      string
	device  string
	viewers map[*liveViewer]struct{}
}

type liveViewer struct {
	conn    *websocket.Conn
	fps     int
	frames  chan []byte // to writeFrames; never more than liveMaxUnacked
	writeMu sync.Mutex
	mu      sync.Mutex
	sent    []int64     // frames queued or written and not acknowledged, by seq
	inputs  []time.Time // inputs of the last second
	closing sync.Once
}

// liveStart is what the relay tells the Mac about a stream: sent when it starts, whenever its
// viewers change and every Config.LiveRenew while it runs.
type liveStart struct {
	Type    string           `json:"type"`
	ID      string           `json:"id"`
	Device  string           `json:"device"`
	FPS     int              `json:"fps"`
	Viewers []liveViewerInfo `json:"viewers"`
}

// liveViewerInfo tells the Mac who watches. Everyone here has the client key; the hosted relay
// also has "owner" (the account in the dashboard) and "share" (a share link, with its label).
type liveViewerInfo struct {
	Kind    string `json:"kind"`
	Label   string `json:"label,omitempty"`
	Control bool   `json:"control"`
}

func isLivePath(path string) bool {
	if path == "/v1/live" {
		return true
	}
	rest, ok := strings.CutPrefix(path, "/h/")
	slash := strings.Index(rest, "/")
	return ok && slash > 0 && rest[slash:] == "/v1/live"
}

// liveSpace reads the client key from Authorization or, for browsers, which cannot set headers
// on a WebSocket, from the "mobdev-auth.<key>" subprotocol.
func liveSpace(r *http.Request) (string, bool) {
	key := bearer(r)
	if key == "" {
		for _, value := range r.Header.Values("Sec-WebSocket-Protocol") {
			for _, token := range strings.Split(value, ",") {
				if credential, ok := strings.CutPrefix(strings.TrimSpace(token), liveAuthPrefix); ok {
					key = credential
				}
			}
		}
	}
	if !strings.HasPrefix(key, "mdc_") || len(key) != 4+64 {
		return "", false
	}
	return spaceID(key), true
}

// liveFPS reads the fps a viewer asks for: 5 without one, at most 10.
func liveFPS(text string) (int, bool) {
	if text == "" {
		return liveDefaultFPS, true
	}
	fps, err := strconv.Atoi(text)
	if err != nil {
		return 0, false
	}
	return min(max(fps, 1), liveMaxFPS), true
}

func (s *Relay) live(w http.ResponseWriter, r *http.Request) {
	space, ok := liveSpace(r)
	if !ok {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeError(w, http.StatusUnauthorized, "missing or malformed client key")
		return
	}
	name, _, _ := hostAndPath(r)
	query := r.URL.Query()
	device := query.Get("device")
	if utf8.RuneCountInString(device) > liveMaxDevice || strings.ContainsFunc(device, unicode.IsControl) {
		writeError(w, http.StatusBadRequest, "device must be a device id or name of at most 200 characters")
		return
	}
	fps, ok := liveFPS(query.Get("fps"))
	if !ok {
		writeError(w, http.StatusBadRequest, "fps must be a number from 1 to 10")
		return
	}
	target, name, ok := s.pickHost(w, space, name)
	if !ok {
		return
	}
	if target.viewerCount() >= liveMaxViewers {
		writeError(w, http.StatusTooManyRequests, fmt.Sprintf("the Mac \"%s\" already has %d viewers", name, liveMaxViewers))
		return
	}
	// Browsers connect from any page, and the key, not a cookie, authenticates them.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{liveSubprotocol}, InsecureSkipVerify: true})
	if err != nil {
		return // Accept already answered.
	}
	defer conn.CloseNow()
	conn.SetReadLimit(64 << 10)
	viewer := &liveViewer{conn: conn, fps: fps, frames: make(chan []byte, liveMaxUnacked)}
	stream, start := target.join(device, viewer)
	if stream == nil {
		_ = conn.Close(websocket.StatusTryAgainLater, "the Mac has too many viewers")
		return
	}
	done := make(chan struct{})
	defer func() {
		close(done)
		if frame := target.leave(stream, viewer); frame != nil {
			_ = target.write(frame, 10*time.Second)
		}
	}()
	hello, _ := json.Marshal(map[string]any{"type": "live", "mac": name, "device": device, "mode": "control", "fps": fps})
	if viewer.write(hello) != nil || target.write(start, 10*time.Second) != nil {
		return
	}
	go viewer.writeFrames(done)

	// A viewer that sends nothing, not even "ping", for IdleTimeout has gone.
	idle := time.AfterFunc(s.cfg.IdleTimeout, func() { viewer.close(closeLiveTimeout, "the viewer sent nothing in time") })
	defer idle.Stop()
	for {
		kind, data, err := conn.Read(context.Background())
		if err != nil {
			return
		}
		idle.Reset(s.cfg.IdleTimeout)
		if kind != websocket.MessageText {
			continue
		}
		if string(data) == "ping" {
			_ = viewer.write([]byte("pong"))
			continue
		}
		var message struct {
			Type string `json:"type"`
			Seq  int64  `json:"seq"`
		}
		if json.Unmarshal(data, &message) != nil {
			continue
		}
		switch message.Type {
		case "ack":
			viewer.ack(message.Seq)
		case "input":
			input, problem := normalizeLiveInput(data)
			if problem == "" && !viewer.allowInput(time.Now()) {
				problem = fmt.Sprintf("too many inputs; at most %d a second", liveMaxInputs)
			}
			if problem != "" {
				_ = viewer.write(liveErrorFrame(problem))
				continue
			}
			frame, _ := json.Marshal(map[string]any{"type": "live_input", "id": stream.id, "input": input})
			if target.write(frame, 10*time.Second) != nil {
				return
			}
		}
	}
}

func liveErrorFrame(message string) []byte {
	data, _ := json.Marshal(map[string]string{"type": "live_error", "message": message})
	return data
}

func liveEndFrame(code, reason string) []byte {
	if code == "" {
		code = "ended"
	}
	data, _ := json.Marshal(map[string]string{"type": "live_end", "code": code, "reason": reason})
	return data
}

// closeReason fits a reason into a close frame, which allows 123 bytes.
func closeReason(reason string) string {
	for len(reason) > 120 {
		_, size := utf8.DecodeLastRuneInString(reason)
		reason = reason[:len(reason)-size]
	}
	return reason
}

func (v *liveViewer) write(data []byte) error {
	v.writeMu.Lock()
	defer v.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return v.conn.Write(ctx, websocket.MessageText, data)
}

// close starts the closing handshake once; the viewer's read loop then ends.
func (v *liveViewer) close(code websocket.StatusCode, reason string) {
	v.closing.Do(func() { go v.conn.Close(code, closeReason(reason)) })
}

// end tells the viewer why its view ends and closes it.
func (v *liveViewer) end(code websocket.StatusCode, frameCode, reason string) {
	go func() {
		_ = v.write(liveEndFrame(frameCode, reason))
		v.close(code, reason)
	}()
}

func (v *liveViewer) writeFrames(done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		case data := <-v.frames:
			if v.write(data) != nil {
				v.close(websocket.StatusGoingAway, "could not send a frame in time")
				return
			}
		}
	}
}

// offer queues a frame unless the viewer has liveMaxUnacked frames unacknowledged.
func (v *liveViewer) offer(seq int64, data []byte) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if len(v.sent) >= liveMaxUnacked {
		return
	}
	select {
	case v.frames <- data:
		v.sent = append(v.sent, seq)
	default:
	}
}

// ack marks every frame up to seq as shown.
func (v *liveViewer) ack(seq int64) {
	v.mu.Lock()
	defer v.mu.Unlock()
	kept := v.sent[:0]
	for _, sent := range v.sent {
		if sent > seq {
			kept = append(kept, sent)
		}
	}
	v.sent = kept
}

func (v *liveViewer) allowInput(now time.Time) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	recent := v.inputs[:0]
	for _, at := range v.inputs {
		if now.Sub(at) < time.Second {
			recent = append(recent, at)
		}
	}
	v.inputs = recent
	if len(v.inputs) >= liveMaxInputs {
		return false
	}
	v.inputs = append(v.inputs, now)
	return true
}

func (h *host) viewerCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	count := 0
	for _, stream := range h.streams {
		count += len(stream.viewers)
	}
	return count
}

// join adds a viewer to the stream of a device, starting one if needed, and returns the
// live_start for the Mac. Nil when the Mac already has liveMaxViewers viewers.
func (h *host) join(device string, v *liveViewer) (*liveStream, []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	count := 0
	for _, stream := range h.streams {
		count += len(stream.viewers)
	}
	if count >= liveMaxViewers {
		return nil, nil
	}
	stream := h.streams[device]
	if stream == nil {
		id, _ := randomID()
		stream = &liveStream{id: id, device: device, viewers: map[*liveViewer]struct{}{}}
		h.streams[device] = stream
	}
	stream.viewers[v] = struct{}{}
	return stream, stream.startFrameLocked()
}

// leave removes a viewer and returns what the Mac needs to hear: live_start for the viewers that
// remain, or live_stop after the last. Nil when the stream had already ended.
func (h *host) leave(stream *liveStream, v *liveViewer) []byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := stream.viewers[v]; !ok {
		return nil
	}
	delete(stream.viewers, v)
	if len(stream.viewers) > 0 {
		return stream.startFrameLocked()
	}
	if h.streams[stream.device] == stream {
		delete(h.streams, stream.device)
	}
	data, _ := json.Marshal(map[string]string{"type": "live_stop", "id": stream.id})
	return data
}

// startFrameLocked builds live_start at the highest fps any viewer asked for. The caller holds h.mu.
func (stream *liveStream) startFrameLocked() []byte {
	start := liveStart{Type: "live_start", ID: stream.id, Device: stream.device, FPS: 1, Viewers: []liveViewerInfo{}}
	for v := range stream.viewers {
		start.FPS = max(start.FPS, v.fps)
		start.Viewers = append(start.Viewers, liveViewerInfo{Kind: "key", Control: true})
	}
	data, _ := json.Marshal(start)
	return data
}

// liveFrame passes a frame from the Mac to the viewers of its stream that are not behind.
func (h *host) liveFrame(env envelope, data []byte) {
	if len(data) > liveMaxFrameBytes {
		return
	}
	var viewers []*liveViewer
	h.mu.Lock()
	for _, stream := range h.streams {
		if stream.id == env.ID {
			for v := range stream.viewers {
				viewers = append(viewers, v)
			}
		}
	}
	h.mu.Unlock()
	for _, v := range viewers {
		v.offer(env.Seq, data)
	}
}

// liveEnd closes the viewers of a stream the Mac ended, e.g. because live view is off there.
func (h *host) liveEnd(env envelope) {
	h.mu.Lock()
	var viewers []*liveViewer
	for device, stream := range h.streams {
		if stream.id == env.ID {
			for v := range stream.viewers {
				viewers = append(viewers, v)
			}
			stream.viewers = map[*liveViewer]struct{}{}
			delete(h.streams, device)
		}
	}
	h.mu.Unlock()
	for _, v := range viewers {
		v.end(closeLiveEnded, env.Code, env.Reason)
	}
}

// endAllStreams closes every viewer of the Mac, when it disconnects.
func (h *host) endAllStreams(code websocket.StatusCode, reason string) {
	h.mu.Lock()
	var viewers []*liveViewer
	for device, stream := range h.streams {
		for v := range stream.viewers {
			viewers = append(viewers, v)
		}
		stream.viewers = map[*liveViewer]struct{}{}
		delete(h.streams, device)
	}
	h.mu.Unlock()
	for _, v := range viewers {
		v.end(code, "mac_offline", reason)
	}
}

// renewStreams repeats live_start for every stream until the Mac disconnects. The Mac ends a stream
// that is not renewed for 75 s, so a lost live_stop cannot keep one running.
func (h *host) renewStreams(every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-h.done:
			return
		case <-ticker.C:
		}
		h.mu.Lock()
		frames := make([][]byte, 0, len(h.streams))
		for _, stream := range h.streams {
			frames = append(frames, stream.startFrameLocked())
		}
		h.mu.Unlock()
		for _, frame := range frames {
			if h.write(frame, 10*time.Second) != nil {
				return
			}
		}
	}
}

// liveInput is a viewer's input as it arrives. normalizeLiveInput checks it and keeps only the
// fields of its action. The hosted relay checks the same way (cloud/relay/src/live.ts).
type liveInput struct {
	Action    string   `json:"action"`
	X         *float64 `json:"x"`
	Y         *float64 `json:"y"`
	FromX     *float64 `json:"from_x"`
	FromY     *float64 `json:"from_y"`
	ToX       *float64 `json:"to_x"`
	ToY       *float64 `json:"to_y"`
	Duration  *float64 `json:"duration"`
	Seconds   *float64 `json:"seconds"`
	Direction string   `json:"direction"`
	Amount    *float64 `json:"amount"`
	Text      *string  `json:"text"`
	Key       string   `json:"key"`
	Modifiers []string `json:"modifiers"`
}

// normalizeLiveInput returns the input to send to the Mac, or why it is refused. Points are
// fractions of the screen from its top-left corner, 0 to 1.
func normalizeLiveInput(data []byte) (map[string]any, string) {
	var in liveInput
	if json.Unmarshal(data, &in) != nil {
		return nil, "input must be a JSON object with an action"
	}
	point := func(values ...*float64) bool {
		for _, value := range values {
			if value == nil || math.IsNaN(*value) || *value < 0 || *value > 1 {
				return false
			}
		}
		return true
	}
	clamp := func(value *float64, fallback, low, high float64) float64 {
		if value == nil || math.IsNaN(*value) {
			return fallback
		}
		return math.Min(math.Max(*value, low), high)
	}
	const pointProblem = "points are fractions of the screen from 0 to 1"
	switch in.Action {
	case "tap":
		if !point(in.X, in.Y) {
			return nil, pointProblem
		}
		return map[string]any{"action": "tap", "x": *in.X, "y": *in.Y}, ""
	case "long_press":
		if !point(in.X, in.Y) {
			return nil, pointProblem
		}
		return map[string]any{"action": "long_press", "x": *in.X, "y": *in.Y, "seconds": clamp(in.Seconds, 1, 0.3, 5)}, ""
	case "swipe":
		if !point(in.FromX, in.FromY, in.ToX, in.ToY) {
			return nil, pointProblem
		}
		return map[string]any{
			"action": "swipe", "from_x": *in.FromX, "from_y": *in.FromY, "to_x": *in.ToX, "to_y": *in.ToY,
			"duration": clamp(in.Duration, 0.3, 0.1, 2),
		}, ""
	case "scroll":
		x, y := 0.5, 0.5
		if in.X != nil || in.Y != nil {
			if !point(in.X, in.Y) {
				return nil, pointProblem
			}
			x, y = *in.X, *in.Y
		}
		switch in.Direction {
		case "up", "down", "left", "right":
		default:
			return nil, "direction must be up, down, left or right"
		}
		amount := math.Round(clamp(in.Amount, 3, 1, 20))
		return map[string]any{"action": "scroll", "x": x, "y": y, "direction": in.Direction, "amount": amount}, ""
	case "text":
		if in.Text == nil || *in.Text == "" || utf8.RuneCountInString(*in.Text) > liveMaxText {
			return nil, fmt.Sprintf("text must have 1 to %d characters", liveMaxText)
		}
		return map[string]any{"action": "text", "text": *in.Text}, ""
	case "key":
		if in.Key == "" || utf8.RuneCountInString(in.Key) > liveMaxKey || strings.ContainsFunc(in.Key, unicode.IsControl) {
			return nil, "key must be a key name such as enter or one character"
		}
		modifiers := []string{}
		for _, modifier := range []string{"cmd", "shift", "option", "ctrl"} {
			for _, given := range in.Modifiers {
				if given == modifier {
					modifiers = append(modifiers, modifier)
					break
				}
			}
		}
		if len(modifiers) != len(in.Modifiers) {
			return nil, "modifiers must be cmd, shift, option or ctrl, each once"
		}
		return map[string]any{"action": "key", "key": in.Key, "modifiers": modifiers}, ""
	case "home":
		return map[string]any{"action": "home"}, ""
	}
	return nil, "action must be tap, long_press, swipe, scroll, text, key or home"
}
