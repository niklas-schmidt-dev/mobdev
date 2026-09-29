package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testSecret = "mdh_0123456789abcdef"

func testConfig() Config {
	cfg := DefaultConfig()
	cfg.PollTimeout = 2 * time.Second
	cfg.RequestTimeout = 3 * time.Second
	return cfg
}

// fakeHost answers every request with the path it received, like a Mac would.
func fakeHost(t *testing.T, baseURL, secret, name string, stop <-chan struct{}) {
	t.Helper()
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			req, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/host/poll?name="+name, nil)
			req.Header.Set("Authorization", "Bearer "+secret)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return
			}
			if resp.StatusCode != http.StatusOK {
				resp.Body.Close()
				continue
			}
			var env envelope
			_ = json.NewDecoder(resp.Body).Decode(&env)
			resp.Body.Close()
			body, _ := base64.StdEncoding.DecodeString(env.Body)
			answer := map[string]string{
				"host": name, "method": env.Method, "path": env.Path, "query": env.Query,
				"body": string(body), "mcp-method": env.Headers["mcp-method"],
			}
			encoded, _ := json.Marshal(answer)
			reply := envelope{
				ID: env.ID, Status: 200, Headers: map[string]string{"Content-Type": "application/json"},
				Body: base64.StdEncoding.EncodeToString(encoded),
			}
			payload, _ := json.Marshal(reply)
			post, _ := http.NewRequest(http.MethodPost, baseURL+"/v1/host/respond", strings.NewReader(string(payload)))
			post.Header.Set("Authorization", "Bearer "+secret)
			if r, err := http.DefaultClient.Do(post); err == nil {
				r.Body.Close()
			}
		}
	}()
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

func waitForHost(t *testing.T, baseURL, key string, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/relay/hosts", nil)
		req.Header.Set("Authorization", "Bearer "+key)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			var list struct{ Hosts []string }
			_ = json.NewDecoder(resp.Body).Decode(&list)
			resp.Body.Close()
			if len(list.Hosts) >= count {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("host did not come online")
}

func TestClientKeyMatchesSwiftDerivation(t *testing.T) {
	want := "mdc_0e465dea368fb6d8eb7a0c146da16c6a88b354216735682efcdf51a0ec3a9ab4"
	if got := ClientKey(testSecret); got != want {
		t.Fatalf("ClientKey = %s, want %s", got, want)
	}
}

func TestForwardsRequestToHostAndBack(t *testing.T) {
	server := httptest.NewServer(NewRelay(testConfig()))
	defer server.Close()
	stop := make(chan struct{})
	defer close(stop)
	fakeHost(t, server.URL, testSecret, "studio", stop)
	key := ClientKey(testSecret)
	waitForHost(t, server.URL, key, 1)

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

func TestRejectsWrongKeys(t *testing.T) {
	server := httptest.NewServer(NewRelay(testConfig()))
	defer server.Close()

	if status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", "", "{}", nil); status != 401 {
		t.Fatalf("missing key: status %d", status)
	}
	// A host secret is not a client key.
	if status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", testSecret, "{}", nil); status != 401 {
		t.Fatalf("host secret as client key: status %d", status)
	}
	// A client key cannot register as a host.
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/host/poll", nil)
	req.Header.Set("Authorization", "Bearer "+ClientKey(testSecret))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("client key as host: status %d", resp.StatusCode)
	}
}

func TestOnlyForwardsMobdevPaths(t *testing.T) {
	server := httptest.NewServer(NewRelay(testConfig()))
	defer server.Close()
	stop := make(chan struct{})
	defer close(stop)
	fakeHost(t, server.URL, testSecret, "studio", stop)
	key := ClientKey(testSecret)
	waitForHost(t, server.URL, key, 1)
	if status, _ := clientRequest(t, http.MethodGet, server.URL+"/healthz/../etc", key, "", nil); status != 404 {
		t.Fatalf("status %d", status)
	}
	if status, _ := clientRequest(t, http.MethodGet, server.URL+"/admin", key, "", nil); status != 404 {
		t.Fatalf("status %d", status)
	}
}

func TestNoHostOnline(t *testing.T) {
	server := httptest.NewServer(NewRelay(testConfig()))
	defer server.Close()
	status, body := clientRequest(t, http.MethodPost, server.URL+"/mcp", ClientKey(testSecret), "{}", nil)
	if status != 503 {
		t.Fatalf("status %d: %v", status, body)
	}
}

func TestSeveralHostsNeedAName(t *testing.T) {
	server := httptest.NewServer(NewRelay(testConfig()))
	defer server.Close()
	stop := make(chan struct{})
	defer close(stop)
	fakeHost(t, server.URL, testSecret, "office", stop)
	fakeHost(t, server.URL, testSecret, "home", stop)
	key := ClientKey(testSecret)
	waitForHost(t, server.URL, key, 2)

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
	server := httptest.NewServer(NewRelay(testConfig()))
	defer server.Close()
	stop := make(chan struct{})
	defer close(stop)
	fakeHost(t, server.URL, testSecret, "studio", stop)
	waitForHost(t, server.URL, ClientKey(testSecret), 1)
	other := ClientKey("mdh_another-secret-value")
	if status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", other, "{}", nil); status != 503 {
		t.Fatalf("another key reached the host: status %d", status)
	}
}

func TestAccessTokenGatesHosts(t *testing.T) {
	cfg := testConfig()
	cfg.AccessToken = "let-me-in"
	server := httptest.NewServer(NewRelay(cfg))
	defer server.Close()
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/host/poll", nil)
	req.Header.Set("Authorization", "Bearer "+testSecret)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestTimesOutWhenHostDoesNotAnswer(t *testing.T) {
	cfg := testConfig()
	cfg.RequestTimeout = 300 * time.Millisecond
	server := httptest.NewServer(NewRelay(cfg))
	defer server.Close()
	// Register a host that polls once and never answers.
	go func() {
		req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/host/poll?name=silent", nil)
		req.Header.Set("Authorization", "Bearer "+testSecret)
		if resp, err := http.DefaultClient.Do(req); err == nil {
			resp.Body.Close()
		}
	}()
	waitForHost(t, server.URL, ClientKey(testSecret), 1)
	status, _ := clientRequest(t, http.MethodPost, server.URL+"/mcp", ClientKey(testSecret), "{}", nil)
	if status != 504 {
		t.Fatalf("status %d", status)
	}
}

func TestImmediatePollConfirmsTheKey(t *testing.T) {
	server := httptest.NewServer(NewRelay(DefaultConfig()))
	defer server.Close()
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/host/poll?name=studio&wait=0", nil)
	req.Header.Set("Authorization", "Bearer "+testSecret)
	start := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || time.Since(start) > time.Second {
		t.Fatalf("status %d after %s", resp.StatusCode, time.Since(start))
	}
}
