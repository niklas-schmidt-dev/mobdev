// Package main is the Mobdev relay: it lets agents reach a Mac running Mobdev without
// opening a port on that Mac. The Mac keeps one outgoing WebSocket open; the relay sends
// each agent request over it and returns the answer. Nothing is stored.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Config controls limits and optional access control.
type Config struct {
	// AccessToken, when set, is required from Macs (X-Relay-Access) before they may connect.
	AccessToken    string
	RequestTimeout time.Duration
	// IdleTimeout closes a Mac's connection when nothing, not even a ping, arrives in time.
	IdleTimeout time.Duration
	MaxBody     int64
	MaxHosts    int
}

func DefaultConfig() Config {
	return Config{
		RequestTimeout: 90 * time.Second,
		IdleTimeout:    75 * time.Second,
		MaxBody:        16 << 20,
		MaxHosts:       32,
	}
}

// envelope is one tunnelled HTTP request ("request") or its answer ("response").
// Bodies are base64.
type envelope struct {
	Type    string            `json:"type"`
	ID      string            `json:"id"`
	Method  string            `json:"method,omitempty"`
	Path    string            `json:"path,omitempty"`
	Query   string            `json:"query,omitempty"`
	Status  int               `json:"status,omitempty"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

// CloseReplaced tells a Mac that another connection with the same key and name took over.
const CloseReplaced websocket.StatusCode = 4000

// Device is an iPhone or iPad attached to a Mac. The Mac sends its list as a text frame
// {"type":"devices","devices":[...]} after connecting and whenever it changes. The hosted
// relay (cloud/shared/devices.ts) validates it the same way.
type Device struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Model       string `json:"model"`
	ModelName   string `json:"model_name"`
	OSVersion   string `json:"os_version"`
	DeviceClass string `json:"device_class"`
	Screen      bool   `json:"screen"`    // the Mac has the device's picture over USB
	Bluetooth   bool   `json:"bluetooth"` // the Mac's Bluetooth keyboard and mouse are connected
	Ready       bool   `json:"ready"`
}

const (
	maxDevices           = 32
	maxDeviceString      = 100
	maxDevicesFrameBytes = 16 << 10
)

// parseDevices validates a "devices" frame: at most 32 devices are kept, strings are cut to
// 100 characters and unknown fields are dropped. The whole frame is rejected when it is larger
// than 16 KB or malformed (not JSON, no devices array, an entry without an id, a field of the
// wrong type).
func parseDevices(data []byte) ([]Device, bool) {
	if len(data) > maxDevicesFrameBytes {
		return nil, false
	}
	var frame struct {
		Type    string    `json:"type"`
		Devices *[]Device `json:"devices"`
	}
	if json.Unmarshal(data, &frame) != nil || frame.Type != "devices" || frame.Devices == nil {
		return nil, false
	}
	devices := *frame.Devices
	for i := range devices {
		d := &devices[i]
		for _, field := range []*string{&d.ID, &d.Name, &d.Model, &d.ModelName, &d.OSVersion, &d.DeviceClass} {
			if runes := []rune(*field); len(runes) > maxDeviceString {
				*field = string(runes[:maxDeviceString])
			}
		}
		if d.ID == "" {
			return nil, false
		}
	}
	if len(devices) > maxDevices {
		devices = devices[:maxDevices]
	}
	return devices, true
}

type host struct {
	conn        *websocket.Conn
	connectedAt time.Time
	writeMu     sync.Mutex
	mu          sync.Mutex
	pending     map[string]chan envelope
	devices     []Device // latest list from the Mac; replaced, never modified in place
	done        chan struct{}
}

func (h *host) write(ctx context.Context, data []byte) error {
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	return h.conn.Write(ctx, websocket.MessageText, data)
}

func (h *host) deliver(env envelope) {
	h.mu.Lock()
	ch := h.pending[env.ID]
	delete(h.pending, env.ID)
	h.mu.Unlock()
	if ch != nil {
		ch <- env
	}
}

type Relay struct {
	cfg    Config
	mu     sync.Mutex
	spaces map[string]map[string]*host
}

func NewRelay(cfg Config) *Relay {
	return &Relay{cfg: cfg, spaces: map[string]map[string]*host{}}
}

const clientKeyContext = "mobdev-relay-client-v1"

var hostNamePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// ClientKey derives the key agents use from the secret only the Mac knows.
func ClientKey(hostSecret string) string {
	mac := hmac.New(sha256.New, []byte(hostSecret))
	mac.Write([]byte(clientKeyContext))
	return "mdc_" + hex.EncodeToString(mac.Sum(nil))
}

func spaceID(clientKey string) string {
	sum := sha256.Sum256([]byte(clientKey))
	return hex.EncodeToString(sum[:])
}

func bearer(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if len(value) > 7 && strings.EqualFold(value[:7], "bearer ") {
		return strings.TrimSpace(value[7:])
	}
	return ""
}

func hostSpace(r *http.Request) (string, bool) {
	secret := bearer(r)
	if !strings.HasPrefix(secret, "mdh_") || len(secret) < 20 || len(secret) > 200 {
		return "", false
	}
	return spaceID(ClientKey(secret)), true
}

func clientSpace(r *http.Request) (string, bool) {
	key := bearer(r)
	if !strings.HasPrefix(key, "mdc_") || len(key) != 4+64 {
		return "", false
	}
	return spaceID(key), true
}

func (s *Relay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/healthz":
		w.Header().Set("Content-Type", "text/plain")
		_, _ = io.WriteString(w, "ok\n")
	case r.URL.Path == "/v1/host/connect":
		s.connect(w, r)
	case r.URL.Path == "/v1/relay/hosts" && r.Method == http.MethodGet:
		s.listHosts(w, r)
	case r.URL.Path == "/v1/relay/devices" && r.Method == http.MethodGet:
		s.listDevices(w, r)
	default:
		s.forward(w, r)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": message})
}

// connect upgrades a Mac's request to the WebSocket that carries agent requests.
func (s *Relay) connect(w http.ResponseWriter, r *http.Request) {
	if s.cfg.AccessToken != "" &&
		subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Relay-Access")), []byte(s.cfg.AccessToken)) != 1 {
		writeError(w, http.StatusForbidden, "this relay requires an access token")
		return
	}
	space, ok := hostSpace(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "missing or malformed host secret")
		return
	}
	name := strings.ToLower(r.URL.Query().Get("name"))
	if name == "" {
		name = "mac"
	}
	if !hostNamePattern.MatchString(name) {
		writeError(w, http.StatusBadRequest, "host name must be 1-64 characters of a-z, 0-9, '.', '_' or '-'")
		return
	}
	s.mu.Lock()
	full := len(s.spaces[space]) >= s.cfg.MaxHosts && s.spaces[space][name] == nil
	s.mu.Unlock()
	if full {
		writeError(w, http.StatusTooManyRequests, "too many Macs share this key")
		return
	}

	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept already answered.
	}
	conn.SetReadLimit(s.cfg.MaxBody * 2)
	h := &host{
		conn:        conn,
		connectedAt: time.Now(),
		pending:     map[string]chan envelope{},
		devices:     []Device{},
		done:        make(chan struct{}),
	}

	s.mu.Lock()
	hosts := s.spaces[space]
	if hosts == nil {
		hosts = map[string]*host{}
		s.spaces[space] = hosts
	}
	previous := hosts[name]
	hosts[name] = h
	s.mu.Unlock()
	if previous != nil {
		go previous.conn.Close(CloseReplaced, "another connection with this key and name took over")
	}
	defer func() {
		s.mu.Lock()
		if s.spaces[space][name] == h {
			delete(s.spaces[space], name)
			if len(s.spaces[space]) == 0 {
				delete(s.spaces, space)
			}
		}
		s.mu.Unlock()
		close(h.done)
		_ = conn.CloseNow()
	}()

	for {
		readCtx, cancel := context.WithTimeout(context.Background(), s.cfg.IdleTimeout)
		kind, data, err := conn.Read(readCtx)
		cancel()
		if err != nil {
			return
		}
		if kind != websocket.MessageText {
			continue
		}
		if string(data) == "ping" {
			writeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err := h.write(writeCtx, []byte("pong"))
			cancel()
			if err != nil {
				return
			}
			continue
		}
		var env envelope
		if json.Unmarshal(data, &env) == nil && env.Type == "response" {
			h.deliver(env)
		} else if devices, ok := parseDevices(data); ok {
			h.mu.Lock()
			h.devices = devices
			h.mu.Unlock()
		}
	}
}

func (s *Relay) listHosts(w http.ResponseWriter, r *http.Request) {
	space, ok := clientSpace(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "missing or malformed client key")
		return
	}
	s.mu.Lock()
	names := []string{}
	for name := range s.spaces[space] {
		names = append(names, name)
	}
	s.mu.Unlock()
	sort.Strings(names)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"hosts": names})
}

// macDevices is one connected Mac in /v1/relay/devices. The hosted relay's
// /v1/account/devices uses the same shape and also lists offline Macs.
type macDevices struct {
	Name           string   `json:"name"`
	Online         bool     `json:"online"`
	ConnectedAt    int64    `json:"connected_at"`
	DisconnectedAt *int64   `json:"disconnected_at"`
	Devices        []Device `json:"devices"`
}

// listDevices lists the connected Macs of the client key's space with the devices they last
// reported, newest connection first.
func (s *Relay) listDevices(w http.ResponseWriter, r *http.Request) {
	space, ok := clientSpace(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "missing or malformed client key")
		return
	}
	s.mu.Lock()
	hosts := make(map[string]*host, len(s.spaces[space]))
	for name, h := range s.spaces[space] {
		hosts[name] = h
	}
	s.mu.Unlock()
	macs := make([]macDevices, 0, len(hosts))
	for name, h := range hosts {
		h.mu.Lock()
		devices := h.devices
		h.mu.Unlock()
		macs = append(macs, macDevices{Name: name, Online: true, ConnectedAt: h.connectedAt.UnixMilli(), Devices: devices})
	}
	sort.Slice(macs, func(i, j int) bool {
		if macs[i].ConnectedAt != macs[j].ConnectedAt {
			return macs[i].ConnectedAt > macs[j].ConnectedAt
		}
		return macs[i].Name < macs[j].Name
	})
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"macs": macs})
}

var forwardedRequestHeaders = []string{"Content-Type", "Accept", "Mcp-Protocol-Version", "Mcp-Method", "Mcp-Name"}
var forwardedResponseHeaders = []string{"Content-Type", "Allow", "X-Image-Width", "X-Image-Height"}

// forward sends an agent's request to the chosen Mac and relays the answer.
func (s *Relay) forward(w http.ResponseWriter, r *http.Request) {
	space, ok := clientSpace(r)
	if !ok {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeError(w, http.StatusUnauthorized, "missing or malformed client key")
		return
	}

	path := r.URL.Path
	name := strings.ToLower(r.Header.Get("X-Mobdev-Host"))
	if strings.HasPrefix(path, "/h/") {
		rest := strings.TrimPrefix(path, "/h/")
		slash := strings.Index(rest, "/")
		if slash <= 0 {
			writeError(w, http.StatusNotFound, "use /h/<mac-name>/<path>")
			return
		}
		name, path = strings.ToLower(rest[:slash]), rest[slash:]
	}
	if path != "/mcp" && !strings.HasPrefix(path, "/v1/") {
		writeError(w, http.StatusNotFound, "not found")
		return
	}

	s.mu.Lock()
	hosts := s.spaces[space]
	target := hosts[name]
	online := make([]string, 0, len(hosts))
	for hostName, h := range hosts {
		online = append(online, hostName)
		if name == "" && len(hosts) == 1 {
			target = h
		}
	}
	s.mu.Unlock()
	switch {
	case target == nil && name != "":
		writeError(w, http.StatusServiceUnavailable, "the Mac \""+name+"\" is not connected")
		return
	case target == nil && len(online) == 0:
		writeError(w, http.StatusServiceUnavailable, "no Mac is connected with this key")
		return
	case target == nil:
		sort.Strings(online)
		writeError(w, http.StatusConflict, "several Macs are connected; use /h/<name>/... with one of: "+strings.Join(online, ", "))
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.cfg.MaxBody))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
		return
	}
	headers := map[string]string{}
	for _, header := range forwardedRequestHeaders {
		if value := r.Header.Get(header); value != "" {
			headers[strings.ToLower(header)] = value
		}
	}
	for header, values := range r.Header {
		if strings.HasPrefix(strings.ToLower(header), "mcp-param-") && len(values) > 0 {
			headers[strings.ToLower(header)] = values[0]
		}
	}

	id, err := randomID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create request id")
		return
	}
	payload, _ := json.Marshal(envelope{
		Type: "request", ID: id, Method: r.Method, Path: path, Query: r.URL.RawQuery, Headers: headers,
		Body: base64.StdEncoding.EncodeToString(body),
	})
	reply := make(chan envelope, 1)
	target.mu.Lock()
	target.pending[id] = reply
	target.mu.Unlock()
	defer func() {
		target.mu.Lock()
		delete(target.pending, id)
		target.mu.Unlock()
	}()

	writeCtx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	err = target.write(writeCtx, payload)
	cancel()
	if err != nil {
		writeError(w, http.StatusBadGateway, "the Mac disconnected")
		return
	}

	timer := time.NewTimer(s.cfg.RequestTimeout)
	defer timer.Stop()
	select {
	case answer := <-reply:
		decoded, err := base64.StdEncoding.DecodeString(answer.Body)
		if err != nil {
			writeError(w, http.StatusBadGateway, "the Mac sent an invalid response")
			return
		}
		for _, header := range forwardedResponseHeaders {
			for key, value := range answer.Headers {
				if strings.EqualFold(key, header) {
					w.Header().Set(header, value)
				}
			}
		}
		status := answer.Status
		if status < 100 || status > 599 {
			status = http.StatusBadGateway
		}
		w.WriteHeader(status)
		_, _ = w.Write(decoded)
	case <-target.done:
		writeError(w, http.StatusBadGateway, "the Mac disconnected")
	case <-timer.C:
		writeError(w, http.StatusGatewayTimeout, "the Mac did not answer in time")
	case <-r.Context().Done():
	}
}

func randomID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
