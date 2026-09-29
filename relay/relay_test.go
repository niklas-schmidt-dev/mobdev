package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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

func newServer(t *testing.T, cfg Config) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(logRequests(NewRelay(cfg)))
	t.Cleanup(server.Close)
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
