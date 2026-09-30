package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const testSecret = "mdh_0123456789abcdef"

func testConfig() Config {
	cfg := DefaultConfig()
	cfg.RequestTimeout = 3 * time.Second
	return cfg
}

// newRelayServer runs the relay with the same http.Server settings as main.
func newRelayServer(t *testing.T, cfg Config) (*httptest.Server, *Relay) {
	t.Helper()
	relay := NewRelay(cfg)
	server := httptest.NewUnstartedServer(nil)
	server.Config = httpServer("", relay)
	server.Start()
	t.Cleanup(server.Close)
	return server, relay
}

func newServer(t *testing.T, cfg Config) *httptest.Server {
	t.Helper()
	server, _ := newRelayServer(t, cfg)
	return server
}

func dialHost(t *testing.T, baseURL, secret, name string, header http.Header) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	if header == nil {
		header = http.Header{}
	}
	header.Set("Authorization", "Bearer "+secret)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(baseURL, "http") + "/v1/host/connect?name=" + name
	return websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: header})
}

// fakeHost answers every request with what it received, like a Mac would. It stops when
// the test ends or the relay closes the connection.
func fakeHost(t *testing.T, baseURL, secret, name string) *websocket.Conn {
	t.Helper()
	conn, _, err := dialHost(t, baseURL, secret, name, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	go func() {
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				return
			}
			var env envelope
			if json.Unmarshal(data, &env) != nil || env.Type != "request" {
				continue
			}
			if env.Path == "/v1/silent" {
				continue // Never answers.
			}
			body, _ := base64.StdEncoding.DecodeString(env.Body)
			answer, _ := json.Marshal(map[string]string{
				"host": name, "method": env.Method, "path": env.Path, "query": env.Query,
				"body": string(body), "mcp-method": env.Headers["mcp-method"],
			})
			reply, _ := json.Marshal(envelope{
				Type: "response", ID: env.ID, Status: 200,
				Headers: map[string]string{"Content-Type": "application/json"},
				Body:    base64.StdEncoding.EncodeToString(answer),
			})
			if conn.Write(context.Background(), websocket.MessageText, reply) != nil {
				return
			}
		}
	}()
	return conn
}

func clientRequest(t *testing.T, method, url, key, body string, headers map[string]string) (int, map[string]string) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	result := map[string]string{}
	_ = json.Unmarshal(data, &result)
	result["_raw"] = string(data)
	return resp.StatusCode, result
}

func waitForHosts(t *testing.T, baseURL, key string, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/relay/hosts", nil)
		req.Header.Set("Authorization", "Bearer "+key)
		if resp, err := http.DefaultClient.Do(req); err == nil {
			var list struct{ Hosts []string }
			_ = json.NewDecoder(resp.Body).Decode(&list)
			resp.Body.Close()
			if len(list.Hosts) == count {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected %d hosts", count)
}

func TestClientKeyMatchesSwiftDerivation(t *testing.T) {
	want := "mdc_0e465dea368fb6d8eb7a0c146da16c6a88b354216735682efcdf51a0ec3a9ab4"
	if got := ClientKey(testSecret); got != want {
		t.Fatalf("ClientKey = %s, want %s", got, want)
	}
}

func TestForwardsRequestToHostAndBack(t *testing.T) {
	server := newServer(t, testConfig())
	fakeHost(t, server.URL, testSecret, "studio")
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)

	status, body := clientRequest(t, http.MethodPost, server.URL+"/mcp", key, `{"jsonrpc":"2.0"}`,
		map[string]string{"Mcp-Method": "tools/call", "Cookie": "secret"})
	if status != 200 {
		t.Fatalf("status %d: %s", status, body["_raw"])
	}
	if body["path"] != "/mcp" || body["method"] != "POST" || body["body"] != `{"jsonrpc":"2.0"}` {
		t.Fatalf("unexpected forward: %v", body)
	}
	if body["mcp-method"] != "tools/call" {
		t.Fatalf("Mcp-Method header was not forwarded: %v", body)
	}

	status, body = clientRequest(t, http.MethodGet, server.URL+"/h/studio/v1/status?x=1", key, "", nil)
	if status != 200 || body["path"] != "/v1/status" || body["query"] != "x=1" {
		t.Fatalf("host path routing failed: %d %v", status, body)
	}
}

func TestAnswersPing(t *testing.T) {
	server := newServer(t, testConfig())
	conn, _, err := dialHost(t, server.URL, testSecret, "studio", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, []byte("ping")); err != nil {
		t.Fatal(err)
	}
	_, data, err := conn.Read(ctx)
	if err != nil || string(data) != "pong" {
		t.Fatalf("got %q, %v", data, err)
	}
}

func TestRejectsWrongKeys(t *testing.T) {
	server := newServer(t, testConfig())
	if status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", "", "{}", nil); status != 401 {
		t.Fatalf("missing key: status %d", status)
	}
	// A host secret is not a client key.
	if status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", testSecret, "{}", nil); status != 401 {
		t.Fatalf("host secret as client key: status %d", status)
	}
	// A client key cannot connect as a host.
	_, resp, err := dialHost(t, server.URL, ClientKey(testSecret), "studio", nil)
	if err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatalf("client key as host: %v %v", resp, err)
	}
}

func TestOnlyForwardsMobdevPaths(t *testing.T) {
	server := newServer(t, testConfig())
	fakeHost(t, server.URL, testSecret, "studio")
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)
	for _, path := range []string{"/healthz/../etc", "/admin", "/h/studio"} {
		if status, _ := clientRequest(t, http.MethodGet, server.URL+path, key, "", nil); status != 404 {
			t.Fatalf("%s: status %d", path, status)
		}
	}
}

func TestNoHostOnline(t *testing.T) {
	server := newServer(t, testConfig())
	status, body := clientRequest(t, http.MethodPost, server.URL+"/mcp", ClientKey(testSecret), "{}", nil)
	if status != 503 {
		t.Fatalf("status %d: %v", status, body)
	}
}

func TestSeveralHostsNeedAName(t *testing.T) {
	server := newServer(t, testConfig())
	fakeHost(t, server.URL, testSecret, "office")
	fakeHost(t, server.URL, testSecret, "home")
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 2)

	status, body := clientRequest(t, http.MethodPost, server.URL+"/mcp", key, "{}", nil)
	if status != 409 || !strings.Contains(body["error"], "home, office") {
		t.Fatalf("expected conflict listing hosts, got %d %v", status, body)
	}
	status, body = clientRequest(t, http.MethodPost, server.URL+"/h/office/mcp", key, "{}", nil)
	if status != 200 || body["host"] != "office" {
		t.Fatalf("expected office, got %d %v", status, body)
	}
	status, body = clientRequest(t, http.MethodPost, server.URL+"/mcp", key, "{}", map[string]string{"X-Mobdev-Host": "home"})
	if status != 200 || body["host"] != "home" {
		t.Fatalf("expected home, got %d %v", status, body)
	}
}

func TestKeysAreIsolated(t *testing.T) {
	server := newServer(t, testConfig())
	fakeHost(t, server.URL, testSecret, "studio")
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	other := ClientKey("mdh_another-secret-value")
	if status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", other, "{}", nil); status != 503 {
		t.Fatalf("another key reached the host: status %d", status)
	}
}

func TestAccessTokenGatesHosts(t *testing.T) {
	cfg := testConfig()
	cfg.AccessToken = "let-me-in"
	server := newServer(t, cfg)
	if _, resp, err := dialHost(t, server.URL, testSecret, "studio", nil); err == nil || resp.StatusCode != 403 {
		t.Fatalf("expected 403 without token, got %v %v", resp, err)
	}
	conn, _, err := dialHost(t, server.URL, testSecret, "studio", http.Header{"X-Relay-Access": {"let-me-in"}})
	if err != nil {
		t.Fatalf("with token: %v", err)
	}
	conn.CloseNow()
}

func TestNewerConnectionReplacesOlder(t *testing.T) {
	server := newServer(t, testConfig())
	// Only this test reads the first connection, so it sees the close frame itself.
	first, _, err := dialHost(t, server.URL, testSecret, "studio", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer first.CloseNow()
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	fakeHost(t, server.URL, testSecret, "studio")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _, err = first.Read(ctx)
	if websocket.CloseStatus(err) != CloseReplaced {
		t.Fatalf("first connection: %v", err)
	}
	status, body := clientRequest(t, http.MethodPost, server.URL+"/mcp", ClientKey(testSecret), "{}", nil)
	if status != 200 {
		t.Fatalf("newer connection should serve: %d %v", status, body)
	}
}

func TestTimesOutWhenHostDoesNotAnswer(t *testing.T) {
	cfg := testConfig()
	cfg.RequestTimeout = 300 * time.Millisecond
	server := newServer(t, cfg)
	fakeHost(t, server.URL, testSecret, "studio")
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	status, _ := clientRequest(t, http.MethodGet, server.URL+"/v1/silent", ClientKey(testSecret), "", nil)
	if status != 504 {
		t.Fatalf("status %d", status)
	}
}

func TestDisconnectFailsPendingRequestsQuickly(t *testing.T) {
	server := newServer(t, testConfig())
	conn := fakeHost(t, server.URL, testSecret, "studio")
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)
	go func() {
		time.Sleep(200 * time.Millisecond)
		conn.Close(websocket.StatusGoingAway, "bye")
	}()
	start := time.Now()
	status, _ := clientRequest(t, http.MethodGet, server.URL+"/v1/silent", key, "", nil)
	if status != 502 || time.Since(start) > 2*time.Second {
		t.Fatalf("status %d after %s", status, time.Since(start))
	}
	waitForHosts(t, server.URL, key, 0)
}

// readFrame reads the next JSON frame the relay sends to a Mac.
func readFrame(t *testing.T, conn *websocket.Conn) envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read frame: %v", err)
	}
	var env envelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("frame %q: %v", data, err)
	}
	return env
}

func answer(t *testing.T, conn *websocket.Conn, id string) {
	t.Helper()
	reply, _ := json.Marshal(envelope{Type: "response", ID: id, Status: 200})
	if err := conn.Write(context.Background(), websocket.MessageText, reply); err != nil {
		t.Fatal(err)
	}
}

// startRequest sends an agent request in the background and reports its status, 0 if it failed.
func startRequest(ctx context.Context, method, url, key string, body io.Reader) <-chan int {
	status := make(chan int, 1)
	go func() {
		req, _ := http.NewRequestWithContext(ctx, method, url, body)
		req.Header.Set("Authorization", "Bearer "+key)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			status <- 0
			return
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		status <- resp.StatusCode
	}()
	return status
}

func receive(t *testing.T, status <-chan int) int {
	t.Helper()
	select {
	case code := <-status:
		return code
	case <-time.After(5 * time.Second):
		t.Fatal("request did not finish")
		return 0
	}
}

func TestStalledRequestBodiesAreCutOff(t *testing.T) {
	cfg := testConfig()
	cfg.BodyTimeout = 300 * time.Millisecond
	server := newServer(t, cfg)
	fakeHost(t, server.URL, testSecret, "studio")
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)

	// The headers promise 10 bytes of body and 4 arrive. Without a key the relay answers without
	// reading the body, and the server then tries to discard the rest; with one the relay reads it.
	for _, attempt := range []struct{ auth, want string }{
		{"", "HTTP/1.1 401"},
		{"Authorization: Bearer " + key + "\r\n", "HTTP/1.1 400"},
	} {
		conn, err := net.Dial("tcp", server.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		fmt.Fprintf(conn, "POST /mcp HTTP/1.1\r\nHost: relay\r\n%sContent-Length: 10\r\n\r\n{\"a\"", attempt.auth)
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		response, err := io.ReadAll(conn)
		if err != nil || !strings.HasPrefix(string(response), attempt.want) {
			t.Fatalf("want %q and a closed connection, got %v %q", attempt.want, err, response)
		}
	}

	// The Mac connected before both deadlines passed; its WebSocket is not affected.
	if status, body := clientRequest(t, http.MethodPost, server.URL+"/mcp", key, "{}", nil); status != 200 {
		t.Fatalf("status %d: %s", status, body["_raw"])
	}
}

func TestHostLimitHoldsForConcurrentRegistrations(t *testing.T) {
	cfg := testConfig()
	cfg.MaxHosts = 3
	server, relay := newRelayServer(t, cfg)
	key := ClientKey(testSecret)

	// Failed upgrades give their place back.
	for range 5 {
		req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/host/connect?name=plain", nil)
		req.Header.Set("Authorization", "Bearer "+testSecret)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusSwitchingProtocols {
			t.Fatal("a plain GET was upgraded")
		}
	}

	var mu sync.Mutex
	var connected []string
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			name := fmt.Sprintf("mac-%d", i)
			conn, resp, err := dialHost(t, server.URL, testSecret, name, nil)
			if err != nil {
				if resp == nil || resp.StatusCode != http.StatusTooManyRequests {
					t.Errorf("%s: %v", name, err)
				}
				return
			}
			t.Cleanup(func() { conn.CloseNow() })
			mu.Lock()
			connected = append(connected, name)
			mu.Unlock()
		}()
	}
	wg.Wait()
	if len(connected) != cfg.MaxHosts {
		t.Fatalf("%d Macs connected, want %d: %v", len(connected), cfg.MaxHosts, connected)
	}
	waitForHosts(t, server.URL, key, cfg.MaxHosts)

	// A Mac reconnecting under its name replaces itself even when the key is full.
	conn, _, err := dialHost(t, server.URL, testSecret, connected[0], nil)
	if err != nil {
		t.Fatalf("reconnect: %v", err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	if _, resp, err := dialHost(t, server.URL, testSecret, "another", nil); err == nil || resp == nil || resp.StatusCode != 429 {
		t.Fatalf("a fourth Mac: %v %v", resp, err)
	}
	waitForHosts(t, server.URL, key, cfg.MaxHosts)
	relay.mu.Lock()
	joining := len(relay.joining)
	relay.mu.Unlock()
	if joining != 0 {
		t.Fatalf("%d spaces still have Macs joining", joining)
	}
}

func TestLimitsRequestsInFlightPerHost(t *testing.T) {
	server := newServer(t, testConfig())
	mac, _, err := dialHost(t, server.URL, testSecret, "studio", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer mac.CloseNow()
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)

	var running []<-chan int
	var ids []string
	for range 4 {
		running = append(running, startRequest(context.Background(), http.MethodGet, server.URL+"/v1/status", key, nil))
		ids = append(ids, readFrame(t, mac).ID)
	}
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/status", nil)
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var refused struct{ Error string }
	_ = json.NewDecoder(resp.Body).Decode(&refused)
	resp.Body.Close()
	want := `the Mac "studio" is already handling 4 requests; send more when one finishes`
	if resp.StatusCode != 429 || resp.Header.Get("Retry-After") != "1" || refused.Error != want {
		t.Fatalf("fifth request: %d, Retry-After %q, %q", resp.StatusCode, resp.Header.Get("Retry-After"), refused.Error)
	}

	// A finished request frees its slot.
	answer(t, mac, ids[0])
	if status := receive(t, running[0]); status != 200 {
		t.Fatalf("first request: %d", status)
	}
	next := startRequest(context.Background(), http.MethodGet, server.URL+"/v1/status", key, nil)
	answer(t, mac, readFrame(t, mac).ID)
	if status := receive(t, next); status != 200 {
		t.Fatalf("request after a slot freed up: %d", status)
	}
	for i := 1; i < len(ids); i++ {
		answer(t, mac, ids[i])
		if status := receive(t, running[i]); status != 200 {
			t.Fatalf("request %d: %d", i, status)
		}
	}
}

func TestLimitsBufferedRequestBodies(t *testing.T) {
	cfg := testConfig()
	cfg.MaxBody = 500
	cfg.MaxBuffered = 1000
	server, relay := newRelayServer(t, cfg)
	mac, _, err := dialHost(t, server.URL, testSecret, "studio", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer mac.CloseNow()
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)
	url := server.URL + "/mcp"

	// 400 bytes with a Content-Length and a body of unknown length, which counts as MaxBody,
	// take 900 of the 1000 bytes.
	sized := startRequest(context.Background(), http.MethodPost, url, key, strings.NewReader(strings.Repeat("x", 400)))
	sizedID := readFrame(t, mac).ID
	chunked := startRequest(context.Background(), http.MethodPost, url, key, io.NopCloser(strings.NewReader("{}")))
	chunkedID := readFrame(t, mac).ID
	if status, body := clientRequest(t, http.MethodPost, url, key, strings.Repeat("x", 200), nil); status != 503 {
		t.Fatalf("over budget: %d %s", status, body["_raw"])
	}

	answer(t, mac, sizedID)
	if status := receive(t, sized); status != 200 {
		t.Fatalf("sized request: %d", status)
	}
	later := startRequest(context.Background(), http.MethodPost, url, key, strings.NewReader(strings.Repeat("x", 200)))
	answer(t, mac, readFrame(t, mac).ID)
	if status := receive(t, later); status != 200 {
		t.Fatalf("request after bytes freed up: %d", status)
	}
	answer(t, mac, chunkedID)
	if status := receive(t, chunked); status != 200 {
		t.Fatalf("chunked request: %d", status)
	}

	if status, _ := clientRequest(t, http.MethodPost, url, key, strings.Repeat("x", 501), nil); status != 413 {
		t.Fatalf("body over MaxBody: %d", status)
	}
	relay.mu.Lock()
	buffered := relay.buffered
	relay.mu.Unlock()
	if buffered != 0 {
		t.Fatalf("%d bytes still reserved", buffered)
	}
}

func TestCancelsRequestsNobodyWaitsFor(t *testing.T) {
	key := ClientKey(testSecret)
	connect := func(cfg Config) (string, *websocket.Conn) {
		server := newServer(t, cfg)
		mac, _, err := dialHost(t, server.URL, testSecret, "studio", nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { mac.CloseNow() })
		waitForHosts(t, server.URL, key, 1)
		return server.URL, mac
	}
	expectCancel := func(mac *websocket.Conn, id string) {
		t.Helper()
		if frame := readFrame(t, mac); frame.Type != "cancel" || frame.ID != id {
			t.Fatalf("expected a cancel frame for %s, got %+v", id, frame)
		}
	}

	// The Mac does not answer in time.
	cfg := testConfig()
	cfg.RequestTimeout = 300 * time.Millisecond
	url, mac := connect(cfg)
	if status, _ := clientRequest(t, http.MethodGet, url+"/v1/status", key, "", nil); status != 504 {
		t.Fatalf("status %d", status)
	}
	expectCancel(mac, readFrame(t, mac).ID)

	// The agent gives up long before the request would time out (3 s).
	url, mac = connect(testConfig())
	ctx, stop := context.WithCancel(context.Background())
	status := startRequest(ctx, http.MethodGet, url+"/v1/status", key, nil)
	id := readFrame(t, mac).ID
	stop()
	expectCancel(mac, id)
	if code := receive(t, status); code != 0 {
		t.Fatalf("cancelled request finished with %d", code)
	}
}

func TestCloseHostsTellsMacsToReconnect(t *testing.T) {
	server, relay := newRelayServer(t, testConfig())
	mac, _, err := dialHost(t, server.URL, testSecret, "studio", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer mac.CloseNow()
	key := ClientKey(testSecret)
	waitForHosts(t, server.URL, key, 1)

	closed := make(chan struct{})
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		relay.CloseHosts(ctx)
		close(closed)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, _, err := mac.Read(ctx); websocket.CloseStatus(err) != websocket.StatusGoingAway {
		t.Fatalf("expected close code 1001, got %v", err)
	}
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("CloseHosts did not return")
	}
	waitForHosts(t, server.URL, key, 0)
}

var testPhone = Device{
	ID: "00008120-000639440C13C01E", Name: "iPhone von Niklas", Model: "iPhone15,2", ModelName: "iPhone 14 Pro",
	OSVersion: "27.0", DeviceClass: "iPhone", Screen: true, Bluetooth: true, Ready: true,
}

func TestParseDevices(t *testing.T) {
	devices, ok := parseDevices([]byte(`{"type":"devices","devices":[{"id":"a","name":"` + strings.Repeat("é", 150) +
		`","serial":"dropped","screen":true},{"id":"b","model_name":null}]}`))
	if !ok || len(devices) != 2 {
		t.Fatalf("valid frame rejected: %v %v", devices, ok)
	}
	if devices[0].Name != strings.Repeat("é", 100) || !devices[0].Screen || devices[0].Bluetooth {
		t.Fatalf("first device: %+v", devices[0])
	}
	if devices[1] != (Device{ID: "b"}) {
		t.Fatalf("second device: %+v", devices[1])
	}
	if devices, ok := parseDevices([]byte(`{"type":"devices","devices":[]}`)); !ok || devices == nil || len(devices) != 0 {
		t.Fatalf("empty list: %v %v", devices, ok)
	}

	many := make([]map[string]string, 40)
	for i := range many {
		many[i] = map[string]string{"id": fmt.Sprintf("device-%d", i)}
	}
	frame, _ := json.Marshal(map[string]any{"type": "devices", "devices": many})
	if devices, ok := parseDevices(frame); !ok || len(devices) != maxDevices || devices[31].ID != "device-31" {
		t.Fatalf("expected the first 32 of 40 devices, got %d %v", len(devices), ok)
	}

	oversized, _ := json.Marshal(map[string]any{"type": "devices", "devices": []Device{{ID: "a", Name: strings.Repeat("x", 17_000)}}})
	for _, bad := range []string{
		`{"type":"devices"`,
		`{"type":"devices"}`,
		`{"type":"devices","devices":null}`,
		`{"type":"devices","devices":{}}`,
		`{"type":"devices","devices":[null]}`,
		`{"type":"devices","devices":[{"name":"no id"}]}`,
		`{"type":"devices","devices":[{"id":"a","screen":"yes"}]}`,
		`{"type":"devices","devices":[{"id":42}]}`,
		`{"type":"response","devices":[]}`,
		`null`,
		string(oversized),
	} {
		if _, ok := parseDevices([]byte(bad)); ok {
			t.Fatalf("accepted %.80s", bad)
		}
	}
}

type devicesList struct {
	Macs []struct {
		Name           string   `json:"name"`
		Online         bool     `json:"online"`
		ConnectedAt    int64    `json:"connected_at"`
		DisconnectedAt *int64   `json:"disconnected_at"`
		Devices        []Device `json:"devices"`
	} `json:"macs"`
}

func listDevices(t *testing.T, baseURL, key string) (int, devicesList) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/relay/devices", nil)
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	var list devicesList
	_ = json.NewDecoder(resp.Body).Decode(&list)
	return resp.StatusCode, list
}

func sendDevices(t *testing.T, conn *websocket.Conn, devices any) {
	t.Helper()
	frame, _ := json.Marshal(map[string]any{"type": "devices", "devices": devices})
	if err := conn.Write(context.Background(), websocket.MessageText, frame); err != nil {
		t.Fatal(err)
	}
}

func waitForDevices(t *testing.T, baseURL, key string, done func(devicesList) bool) devicesList {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		_, list := listDevices(t, baseURL, key)
		if done(list) {
			return list
		}
		if time.Now().After(deadline) {
			t.Fatalf("devices did not arrive: %+v", list)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestListsDevicesOfConnectedHosts(t *testing.T) {
	server := newServer(t, testConfig())
	key := ClientKey(testSecret)
	if status, _ := listDevices(t, server.URL, ""); status != 401 {
		t.Fatalf("missing key: status %d", status)
	}
	if status, list := listDevices(t, server.URL, key); status != 200 || list.Macs == nil || len(list.Macs) != 0 {
		t.Fatalf("no hosts: %d %+v", status, list)
	}

	studio := fakeHost(t, server.URL, testSecret, "studio")
	fakeHost(t, server.URL, testSecret, "office")
	waitForHosts(t, server.URL, key, 2)
	sendDevices(t, studio, []Device{testPhone})
	list := waitForDevices(t, server.URL, key, func(list devicesList) bool {
		for _, mac := range list.Macs {
			if mac.Name == "studio" && len(mac.Devices) == 1 {
				return true
			}
		}
		return false
	})
	if len(list.Macs) != 2 {
		t.Fatalf("expected two Macs: %+v", list)
	}
	for _, mac := range list.Macs {
		if !mac.Online || mac.ConnectedAt == 0 || mac.DisconnectedAt != nil || mac.Devices == nil {
			t.Fatalf("unexpected entry: %+v", mac)
		}
		if mac.Name == "studio" && mac.Devices[0] != testPhone {
			t.Fatalf("studio devices: %+v", mac.Devices)
		}
		if mac.Name == "office" && len(mac.Devices) != 0 {
			t.Fatalf("office should have no devices yet: %+v", mac.Devices)
		}
	}
	if _, other := listDevices(t, server.URL, ClientKey("mdh_another-secret-value")); len(other.Macs) != 0 {
		t.Fatalf("another key sees Macs: %+v", other)
	}

	// Malformed frames leave the list alone. The relay reads a Mac's frames in order, so once
	// the Mac has answered a request sent after them, they have been handled.
	for _, bad := range []string{`{"type":"devices","devices":[{"name":"no id"}]}`, `{"type":"devices"`, `null`} {
		if err := studio.Write(context.Background(), websocket.MessageText, []byte(bad)); err != nil {
			t.Fatal(err)
		}
	}
	if status, _ := clientRequest(t, http.MethodGet, server.URL+"/h/studio/v1/status", key, "", nil); status != 200 {
		t.Fatalf("round trip: status %d", status)
	}
	_, list = listDevices(t, server.URL, key)
	for _, mac := range list.Macs {
		if mac.Name == "studio" && (len(mac.Devices) != 1 || mac.Devices[0] != testPhone) {
			t.Fatalf("malformed frame changed the list: %+v", mac.Devices)
		}
	}

	sendDevices(t, studio, []Device{})
	waitForDevices(t, server.URL, key, func(list devicesList) bool {
		for _, mac := range list.Macs {
			if mac.Name == "studio" {
				return len(mac.Devices) == 0
			}
		}
		return false
	})

	// Only connected Macs are listed.
	studio.Close(websocket.StatusNormalClosure, "bye")
	waitForHosts(t, server.URL, key, 1)
	if _, list := listDevices(t, server.URL, key); len(list.Macs) != 1 || list.Macs[0].Name != "office" {
		t.Fatalf("after disconnect: %+v", list)
	}
}
