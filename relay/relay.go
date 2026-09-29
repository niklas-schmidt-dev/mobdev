// Package main is the Mobdev relay: it lets agents reach a Mac running Mobdev without
// opening a port on that Mac. The Mac keeps outgoing long-poll requests open; the relay
// hands each client request to one of them and returns the answer. Nothing is stored.
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
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Config controls limits and optional access control.
type Config struct {
	// AccessToken, when set, is required from Macs (X-Relay-Access) before they may register.
	AccessToken    string
	RequestTimeout time.Duration
	PollTimeout    time.Duration
	HostTTL        time.Duration
	MaxBody        int64
	QueueSize      int
	MaxHosts       int
}

func DefaultConfig() Config {
	return Config{
		RequestTimeout: 90 * time.Second,
		PollTimeout:    25 * time.Second,
		HostTTL:        45 * time.Second,
		MaxBody:        16 << 20,
		QueueSize:      64,
		MaxHosts:       32,
	}
}

// envelope is one tunnelled HTTP request or response. Bodies are base64.
type envelope struct {
	ID      string            `json:"id"`
	Method  string            `json:"method,omitempty"`
	Path    string            `json:"path,omitempty"`
	Query   string            `json:"query,omitempty"`
	Status  int               `json:"status,omitempty"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

type pending struct {
	env   envelope
	space string
	ctx   context.Context
	reply chan envelope
}

type host struct {
	name     string
	queue    chan *pending
	lastSeen time.Time
	polling  int
}

type Relay struct {
	cfg      Config
	mu       sync.Mutex
	spaces   map[string]map[string]*host
	inflight map[string]*pending
}

func NewRelay(cfg Config) *Relay {
	return &Relay{cfg: cfg, spaces: map[string]map[string]*host{}, inflight: map[string]*pending{}}
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

func (s *Relay) hostSpace(r *http.Request) (string, bool) {
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
	case r.URL.Path == "/v1/host/poll" && r.Method == http.MethodGet:
		s.poll(w, r)
	case r.URL.Path == "/v1/host/respond" && r.Method == http.MethodPost:
		s.respond(w, r)
	case r.URL.Path == "/v1/relay/hosts" && r.Method == http.MethodGet:
		s.listHosts(w, r)
	default:
		s.forward(w, r)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": message})
}

func (s *Relay) authorizeHost(w http.ResponseWriter, r *http.Request) (string, bool) {
	if s.cfg.AccessToken != "" &&
		subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Relay-Access")), []byte(s.cfg.AccessToken)) != 1 {
		writeError(w, http.StatusForbidden, "this relay requires an access token")
		return "", false
	}
	space, ok := s.hostSpace(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "missing or malformed host secret")
		return "", false
	}
	return space, true
}

func (s *Relay) online(h *host) bool {
	return h.polling > 0 || time.Since(h.lastSeen) < s.cfg.HostTTL
}

// prune drops hosts that have been gone for a while. Caller holds s.mu.
func (s *Relay) prune(space string) {
	for name, h := range s.spaces[space] {
		if h.polling == 0 && time.Since(h.lastSeen) > 10*time.Minute {
			delete(s.spaces[space], name)
		}
	}
	if len(s.spaces[space]) == 0 {
		delete(s.spaces, space)
	}
}

func (s *Relay) poll(w http.ResponseWriter, r *http.Request) {
	space, ok := s.authorizeHost(w, r)
	if !ok {
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
	s.prune(space)
	hosts := s.spaces[space]
	if hosts == nil {
		hosts = map[string]*host{}
		s.spaces[space] = hosts
	}
	h := hosts[name]
	if h == nil {
		if len(hosts) >= s.cfg.MaxHosts {
			s.mu.Unlock()
			writeError(w, http.StatusTooManyRequests, "too many Macs share this key")
			return
		}
		h = &host{name: name, queue: make(chan *pending, s.cfg.QueueSize)}
		hosts[name] = h
	}
	h.polling++
	h.lastSeen = time.Now()
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		h.polling--
		h.lastSeen = time.Now()
		s.mu.Unlock()
	}()

	// wait=0 asks for an immediate answer, so a Mac can confirm its key without a long wait.
	timeout := s.cfg.PollTimeout
	if r.URL.Query().Get("wait") == "0" {
		timeout = 0
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case p := <-h.queue:
			if p.ctx.Err() != nil {
				continue // The client gave up before a Mac picked the request up.
			}
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(p.env); err != nil {
				log.Printf("poll write failed: %v", err)
			}
			return
		case <-timer.C:
			w.WriteHeader(http.StatusNoContent)
			return
		case <-r.Context().Done():
			return
		}
	}
}

func (s *Relay) respond(w http.ResponseWriter, r *http.Request) {
	space, ok := s.authorizeHost(w, r)
	if !ok {
		return
	}
	var env envelope
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, s.cfg.MaxBody*2)).Decode(&env); err != nil {
		writeError(w, http.StatusBadRequest, "invalid response envelope")
		return
	}
	s.mu.Lock()
	p := s.inflight[env.ID]
	if p != nil && p.space == space {
		delete(s.inflight, env.ID)
	} else {
		p = nil
	}
	s.mu.Unlock()
	if p == nil {
		writeError(w, http.StatusNotFound, "unknown or expired request")
		return
	}
	select {
	case p.reply <- env:
	default:
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Relay) listHosts(w http.ResponseWriter, r *http.Request) {
	space, ok := clientSpace(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "missing or malformed client key")
		return
	}
	s.mu.Lock()
	s.prune(space)
	names := []string{}
	for name, h := range s.spaces[space] {
		if s.online(h) {
			names = append(names, name)
		}
	}
	s.mu.Unlock()
	sort.Strings(names)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"hosts": names})
}

var forwardedRequestHeaders = []string{"Content-Type", "Accept", "Mcp-Protocol-Version", "Mcp-Method", "Mcp-Name"}
var forwardedResponseHeaders = []string{"Content-Type", "Allow", "X-Image-Width", "X-Image-Height"}

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
	s.prune(space)
	var target *host
	var online []string
	for hostName, h := range s.spaces[space] {
		if s.online(h) {
			online = append(online, hostName)
			if hostName == name {
				target = h
			}
		}
	}
	if name == "" && len(online) == 1 {
		target = s.spaces[space][online[0]]
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
	p := &pending{
		env: envelope{
			ID: id, Method: r.Method, Path: path, Query: r.URL.RawQuery, Headers: headers,
			Body: base64.StdEncoding.EncodeToString(body),
		},
		space: space,
		ctx:   r.Context(),
		reply: make(chan envelope, 1),
	}
	s.mu.Lock()
	s.inflight[id] = p
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.inflight, id)
		s.mu.Unlock()
	}()

	select {
	case target.queue <- p:
	default:
		writeError(w, http.StatusServiceUnavailable, "the Mac is busy; try again")
		return
	}

	timer := time.NewTimer(s.cfg.RequestTimeout)
	defer timer.Stop()
	select {
	case reply := <-p.reply:
		decoded, err := base64.StdEncoding.DecodeString(reply.Body)
		if err != nil {
			writeError(w, http.StatusBadGateway, "the Mac sent an invalid response")
			return
		}
		for _, header := range forwardedResponseHeaders {
			for key, value := range reply.Headers {
				if strings.EqualFold(key, header) {
					w.Header().Set(header, value)
				}
			}
		}
		status := reply.Status
		if status < 100 || status > 599 {
			status = http.StatusBadGateway
		}
		w.WriteHeader(status)
		_, _ = w.Write(decoded)
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
