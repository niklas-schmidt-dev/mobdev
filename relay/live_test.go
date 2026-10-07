package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// liveMac is a fake Mac for live view: it records the relay's live frames and, while a stream
// runs, sends a frame every interval.
type liveMac struct {
	conn     *websocket.Conn
	mu       sync.Mutex
	frames   []map[string]any // live_start, live_stop and live_input from the relay
	streams  map[string]chan struct{}
	interval time.Duration
	writeMu  sync.Mutex
}

func newLiveMac(t *testing.T, baseURL, name string, interval time.Duration) *liveMac {
	t.Helper()
	conn, _, err := dialHost(t, baseURL, testSecret, name, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	mac := &liveMac{conn: conn, streams: map[string]chan struct{}{}, interval: interval}
	t.Cleanup(func() { conn.CloseNow() })
	go func() {
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				return
			}
			var frame map[string]any
			if json.Unmarshal(data, &frame) != nil {
				continue
			}
			mac.mu.Lock()
			mac.frames = append(mac.frames, frame)
			id, _ := frame["id"].(string)
			switch frame["type"] {
			case "live_start":
				if _, running := mac.streams[id]; !running && mac.interval > 0 {
					stop := make(chan struct{})
					mac.streams[id] = stop
					go mac.stream(id, stop)
				}
			case "live_stop":
				if stop, running := mac.streams[id]; running {
					close(stop)
					delete(mac.streams, id)
				}
			}
			mac.mu.Unlock()
		}
	}()
	return mac
}

func (m *liveMac) send(frame any) error {
	data, ok := frame.([]byte)
	if !ok {
		data, _ = json.Marshal(frame)
	}
	m.writeMu.Lock()
	defer m.writeMu.Unlock()
	return m.conn.Write(context.Background(), websocket.MessageText, data)
}

func (m *liveMac) stream(id string, stop chan struct{}) {
	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()
	for seq := int64(1); ; seq++ {
		select {
		case <-stop:
			return
		case <-ticker.C:
		}
		frame := map[string]any{"type": "live_frame", "id": id, "seq": seq, "width": 390, "height": 844, "jpeg": "/9j/AAAA"}
		if m.send(frame) != nil {
			return
		}
	}
}

// received returns the relay's frames of one type, in order.
func (m *liveMac) received(kind string) []map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	var frames []map[string]any
	for _, frame := range m.frames {
		if frame["type"] == kind {
			frames = append(frames, frame)
		}
	}
	return frames
}

func waitFor(t *testing.T, what string, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

type viewerConn struct {
	conn *websocket.Conn
}

func dialViewer(t *testing.T, baseURL, path string, header http.Header, protocols ...string) (*viewerConn, *http.Response, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(baseURL, "http") + path
	conn, response, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: header, Subprotocols: protocols})
	if err != nil {
		return nil, response, err
	}
	conn.SetReadLimit(4 << 20)
	t.Cleanup(func() { conn.CloseNow() })
	return &viewerConn{conn: conn}, response, nil
}

func keyHeader() http.Header {
	return http.Header{"Authorization": {"Bearer " + ClientKey(testSecret)}}
}

// next reads the next JSON message, skipping "pong".
func (v *viewerConn) next(t *testing.T) map[string]any {
	t.Helper()
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, data, err := v.conn.Read(ctx)
		cancel()
		if err != nil {
			t.Fatalf("viewer read: %v", err)
		}
		if string(data) == "pong" {
			continue
		}
		var message map[string]any
		if err := json.Unmarshal(data, &message); err != nil {
			t.Fatalf("viewer got %q", data)
		}
		return message
	}
}

func (v *viewerConn) send(t *testing.T, message any) {
	t.Helper()
	data, _ := json.Marshal(message)
	if err := v.conn.Write(context.Background(), websocket.MessageText, data); err != nil {
		t.Fatalf("viewer write: %v", err)
	}
}

// closeStatus reads until the relay closes the connection and returns its code.
func (v *viewerConn) closeStatus(t *testing.T) (websocket.StatusCode, []map[string]any) {
	t.Helper()
	var messages []map[string]any
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, data, err := v.conn.Read(ctx)
		cancel()
		if err != nil {
			var closeError websocket.CloseError
			if errors.As(err, &closeError) {
				return closeError.Code, messages
			}
			t.Fatalf("expected a close, got %v", err)
		}
		var message map[string]any
		if json.Unmarshal(data, &message) == nil {
			messages = append(messages, message)
		}
	}
}

func TestLiveStreamsFramesToAViewer(t *testing.T) {
	server := newServer(t, testConfig())
	mac := newLiveMac(t, server.URL, "studio", 20*time.Millisecond)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)

	viewer, response, err := dialViewer(t, server.URL, "/h/studio/v1/live?device=00008120-ABC&fps=7", keyHeader())
	if err != nil {
		t.Fatalf("dial viewer: %v (%v)", err, response)
	}
	hello := viewer.next(t)
	if hello["type"] != "live" || hello["mac"] != "studio" || hello["device"] != "00008120-ABC" || hello["mode"] != "control" || hello["fps"] != float64(7) {
		t.Fatalf("hello = %v", hello)
	}
	waitFor(t, "live_start", func() bool { return len(mac.received("live_start")) == 1 })
	start := mac.received("live_start")[0]
	if start["device"] != "00008120-ABC" || start["fps"] != float64(7) || len(start["viewers"].([]any)) != 1 {
		t.Fatalf("live_start = %v", start)
	}
	for seq := 1; seq <= 5; seq++ {
		frame := viewer.next(t)
		if frame["type"] != "live_frame" || frame["id"] != start["id"] || frame["jpeg"] != "/9j/AAAA" || frame["width"] != float64(390) {
			t.Fatalf("frame = %v", frame)
		}
		viewer.send(t, map[string]any{"type": "ack", "seq": frame["seq"]})
	}

	// Leaving stops the stream on the Mac.
	viewer.conn.Close(websocket.StatusNormalClosure, "")
	waitFor(t, "live_stop", func() bool { return len(mac.received("live_stop")) == 1 })
	if stop := mac.received("live_stop")[0]; stop["id"] != start["id"] {
		t.Fatalf("live_stop = %v", stop)
	}
}

func TestLiveAcceptsTheKeyAsSubprotocolForBrowsers(t *testing.T) {
	server := newServer(t, testConfig())
	newLiveMac(t, server.URL, "studio", 0)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)

	viewer, _, err := dialViewer(t, server.URL, "/v1/live", nil, liveSubprotocol, liveAuthPrefix+ClientKey(testSecret))
	if err != nil {
		t.Fatalf("dial viewer: %v", err)
	}
	if got := viewer.conn.Subprotocol(); got != liveSubprotocol {
		t.Fatalf("subprotocol = %q", got)
	}
	if hello := viewer.next(t); hello["type"] != "live" || hello["fps"] != float64(5) || hello["device"] != "" {
		t.Fatalf("hello = %v", hello)
	}

	_, response, err := dialViewer(t, server.URL, "/v1/live", nil, liveSubprotocol, liveAuthPrefix+ClientKey("mdh_someone-else"))
	if err == nil || response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("a key without a Mac: %v %v", err, response)
	}
	_, response, err = dialViewer(t, server.URL, "/v1/live", nil, liveSubprotocol)
	if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no key: %v %v", err, response)
	}
	_, response, err = dialViewer(t, server.URL, "/v1/live?fps=fast", keyHeader())
	if err == nil || response == nil || response.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad fps: %v %v", err, response)
	}
}

func TestLiveViewersOfADeviceShareOneStream(t *testing.T) {
	server := newServer(t, testConfig())
	mac := newLiveMac(t, server.URL, "studio", 20*time.Millisecond)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)

	first, _, err := dialViewer(t, server.URL, "/v1/live?device=phone&fps=3", keyHeader())
	if err != nil {
		t.Fatal(err)
	}
	first.next(t)
	second, _, err := dialViewer(t, server.URL, "/v1/live?device=phone&fps=9", keyHeader())
	if err != nil {
		t.Fatal(err)
	}
	second.next(t)
	waitFor(t, "the second live_start", func() bool { return len(mac.received("live_start")) == 2 })
	starts := mac.received("live_start")
	if starts[0]["id"] != starts[1]["id"] || starts[1]["fps"] != float64(9) || len(starts[1]["viewers"].([]any)) != 2 {
		t.Fatalf("live_start frames = %v", starts)
	}
	for _, viewer := range []*viewerConn{first, second} {
		frame := viewer.next(t)
		if frame["type"] != "live_frame" || frame["id"] != starts[0]["id"] {
			t.Fatalf("frame = %v", frame)
		}
	}

	// One leaves: the stream goes on for the other at its fps.
	second.conn.Close(websocket.StatusNormalClosure, "")
	waitFor(t, "the third live_start", func() bool { return len(mac.received("live_start")) == 3 })
	if start := mac.received("live_start")[2]; start["fps"] != float64(3) || len(start["viewers"].([]any)) != 1 {
		t.Fatalf("live_start after one left = %v", start)
	}
	if len(mac.received("live_stop")) != 0 {
		t.Fatal("the stream stopped while someone still watches")
	}
}

// A viewer that does not acknowledge frames gets two and then none, while one that does keeps up.
func TestLiveSkipsFramesForSlowViewers(t *testing.T) {
	server := newServer(t, testConfig())
	mac := newLiveMac(t, server.URL, "studio", 0)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	slow, _, _ := dialViewer(t, server.URL, "/v1/live?device=phone", keyHeader())
	slow.next(t)
	fast, _, _ := dialViewer(t, server.URL, "/v1/live?device=phone", keyHeader())
	fast.next(t)
	waitFor(t, "live_start", func() bool { return len(mac.received("live_start")) == 2 })
	id := mac.received("live_start")[0]["id"]

	for seq := 1; seq <= 10; seq++ {
		if err := mac.send(map[string]any{"type": "live_frame", "id": id, "seq": seq, "width": 1, "height": 1, "jpeg": ""}); err != nil {
			t.Fatal(err)
		}
		frame := fast.next(t)
		if frame["seq"] != float64(seq) {
			t.Fatalf("fast viewer got %v, want seq %d", frame, seq)
		}
		fast.send(t, map[string]any{"type": "ack", "seq": seq})
	}
	var slowSeqs []float64
	for len(slowSeqs) < 2 {
		slowSeqs = append(slowSeqs, slow.next(t)["seq"].(float64))
	}
	if slowSeqs[0] != 1 || slowSeqs[1] != 2 {
		t.Fatalf("slow viewer got %v", slowSeqs)
	}
	// Caught up: the next frame reaches it again.
	slow.send(t, map[string]any{"type": "ack", "seq": 2})
	time.Sleep(50 * time.Millisecond)
	if err := mac.send(map[string]any{"type": "live_frame", "id": id, "seq": 11, "width": 1, "height": 1, "jpeg": ""}); err != nil {
		t.Fatal(err)
	}
	if frame := slow.next(t); frame["seq"] != float64(11) {
		t.Fatalf("slow viewer after catching up got %v", frame)
	}
}

func TestLiveInputReachesTheMacChecked(t *testing.T) {
	server := newServer(t, testConfig())
	mac := newLiveMac(t, server.URL, "studio", 0)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	viewer, _, _ := dialViewer(t, server.URL, "/v1/live?device=phone", keyHeader())
	viewer.next(t)
	waitFor(t, "live_start", func() bool { return len(mac.received("live_start")) == 1 })
	id := mac.received("live_start")[0]["id"]

	viewer.send(t, map[string]any{"type": "input", "action": "tap", "x": 0.5, "y": 0.25, "extra": "dropped"})
	viewer.send(t, map[string]any{"type": "input", "action": "swipe", "from_x": 0.5, "from_y": 0.8, "to_x": 0.5, "to_y": 0.2, "duration": 9})
	viewer.send(t, map[string]any{"type": "input", "action": "key", "key": "enter", "modifiers": []string{"shift", "cmd"}})
	viewer.send(t, map[string]any{"type": "input", "action": "text", "text": "Grüße"})
	viewer.send(t, map[string]any{"type": "input", "action": "home"})
	waitFor(t, "five inputs", func() bool { return len(mac.received("live_input")) == 5 })
	inputs := mac.received("live_input")
	want := []string{
		`{"action":"tap","x":0.5,"y":0.25}`,
		`{"action":"swipe","duration":2,"from_x":0.5,"from_y":0.8,"to_x":0.5,"to_y":0.2}`,
		`{"action":"key","key":"enter","modifiers":["cmd","shift"]}`,
		`{"action":"text","text":"Grüße"}`,
		`{"action":"home"}`,
	}
	for index, input := range inputs {
		if input["id"] != id {
			t.Fatalf("input %d for stream %v", index, input["id"])
		}
		got, _ := json.Marshal(input["input"])
		if string(got) != want[index] {
			t.Fatalf("input %d = %s, want %s", index, got, want[index])
		}
	}

	for _, bad := range []map[string]any{
		{"type": "input", "action": "tap", "x": 1.5, "y": 0.2},
		{"type": "input", "action": "tap", "x": 0.5},
		{"type": "input", "action": "text", "text": strings.Repeat("a", 1001)},
		{"type": "input", "action": "key", "key": "a", "modifiers": []string{"hyper"}},
		{"type": "input", "action": "reboot"},
	} {
		viewer.send(t, bad)
		if message := viewer.next(t); message["type"] != "live_error" {
			t.Fatalf("%v answered %v", bad, message)
		}
	}
	// More than ten a second are refused.
	for range 12 {
		viewer.send(t, map[string]any{"type": "input", "action": "home"})
	}
	if message := viewer.next(t); message["type"] != "live_error" || !strings.Contains(message["message"].(string), "too many") {
		t.Fatalf("burst answered %v", message)
	}
	time.Sleep(50 * time.Millisecond)
	if got := len(mac.received("live_input")); got > 5+liveMaxInputs {
		t.Fatalf("the Mac got %d inputs", got)
	}
}

func TestLiveEndsWhenTheMacEndsOrLeaves(t *testing.T) {
	server := newServer(t, testConfig())
	mac := newLiveMac(t, server.URL, "studio", 0)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	viewer, _, _ := dialViewer(t, server.URL, "/v1/live?device=phone", keyHeader())
	viewer.next(t)
	waitFor(t, "live_start", func() bool { return len(mac.received("live_start")) == 1 })
	id := mac.received("live_start")[0]["id"]

	if err := mac.send(map[string]any{"type": "live_end", "id": id, "code": "disabled", "reason": "Live view is off on this Mac."}); err != nil {
		t.Fatal(err)
	}
	code, messages := viewer.closeStatus(t)
	if code != closeLiveEnded || len(messages) != 1 || messages[0]["code"] != "disabled" || messages[0]["reason"] != "Live view is off on this Mac." {
		t.Fatalf("closed with %d after %v", code, messages)
	}

	viewer, _, _ = dialViewer(t, server.URL, "/v1/live?device=phone", keyHeader())
	viewer.next(t)
	mac.conn.Close(websocket.StatusNormalClosure, "bye")
	code, messages = viewer.closeStatus(t)
	if code != closeLiveMacGone || len(messages) != 1 || messages[0]["code"] != "mac_offline" {
		t.Fatalf("closed with %d after %v", code, messages)
	}
}

func TestLiveRenewsStreamsAndDropsSilentViewers(t *testing.T) {
	cfg := testConfig()
	cfg.LiveRenew = 30 * time.Millisecond
	cfg.IdleTimeout = 300 * time.Millisecond
	server := newServer(t, cfg)
	mac := newLiveMac(t, server.URL, "studio", 0)
	go func() { // The Mac pings, or the short idle timeout would drop it too.
		for mac.send([]byte("ping")) == nil {
			time.Sleep(50 * time.Millisecond)
		}
	}()
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	viewer, _, _ := dialViewer(t, server.URL, "/v1/live?device=phone", keyHeader())
	viewer.next(t)
	waitFor(t, "renewals", func() bool { return len(mac.received("live_start")) >= 4 })

	// Pings keep a viewer; silence ends it.
	for range 3 {
		if err := viewer.conn.Write(context.Background(), websocket.MessageText, []byte("ping")); err != nil {
			t.Fatal(err)
		}
		time.Sleep(150 * time.Millisecond)
	}
	if len(mac.received("live_stop")) != 0 {
		t.Fatal("a viewer that pings was dropped")
	}
	code, _ := viewer.closeStatus(t)
	if code != closeLiveTimeout {
		t.Fatalf("a silent viewer closed with %d", code)
	}
	waitFor(t, "live_stop", func() bool { return len(mac.received("live_stop")) == 1 })
}

func TestLiveLimitsViewersPerMac(t *testing.T) {
	server := newServer(t, testConfig())
	newLiveMac(t, server.URL, "studio", 0)
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	for index := range liveMaxViewers {
		viewer, _, err := dialViewer(t, server.URL, fmt.Sprintf("/v1/live?device=phone-%d", index%3), keyHeader())
		if err != nil {
			t.Fatalf("viewer %d: %v", index, err)
		}
		viewer.next(t)
	}
	_, response, err := dialViewer(t, server.URL, "/v1/live?device=phone-0", keyHeader())
	if err == nil || response == nil || response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("one viewer too many: %v %v", err, response)
	}
}
