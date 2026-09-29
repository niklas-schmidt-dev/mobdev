package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
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
	first := fakeHost(t, server.URL, testSecret, "studio")
	waitForHosts(t, server.URL, ClientKey(testSecret), 1)
	fakeHost(t, server.URL, testSecret, "studio")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _, err := first.Read(ctx)
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
