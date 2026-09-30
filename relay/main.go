package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	addr := os.Getenv("RELAY_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	cfg := DefaultConfig()
	cfg.AccessToken = os.Getenv("RELAY_HOST_ACCESS_TOKEN")
	relay := NewRelay(cfg)
	server := httpServer(addr, relay)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		<-ctx.Done()
		// Requests in flight get 5 s to finish, then the Macs are told to reconnect.
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
		closing, cancelClosing := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancelClosing()
		relay.CloseHosts(closing)
	}()

	access := "open registration"
	if cfg.AccessToken != "" {
		access = "access token required"
	}
	log.Printf("mobdev relay listening on %s (%s)", addr, access)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-stopped // ListenAndServe returns as soon as Shutdown begins.
}

// httpServer serves the relay. Headers must arrive within 10 s and a whole request within
// BodyTimeout, including a small unread body the server discards after answering, so clients
// that stall cannot hold connections. Hijacking a Mac's connection for its WebSocket clears
// these deadlines; the WebSocket has its own idle timeout.
func httpServer(addr string, relay *Relay) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           logRequests(relay),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       relay.cfg.BodyTimeout,
		IdleTimeout:       120 * time.Second,
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(body []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(body)
}

// Hijack lets WebSocket upgrades through the logging wrapper.
func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("hijacking is not supported")
	}
	if r.status == 0 {
		r.status = http.StatusSwitchingProtocols
	}
	return hijacker.Hijack()
}

func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// logRequests logs method, path, status and duration. Never headers or bodies.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		status := "closed"
		if recorder.status != 0 {
			status = fmt.Sprintf("%d %s", recorder.status, http.StatusText(recorder.status))
		}
		log.Printf("%s %s %s %s", r.Method, r.URL.Path, status, time.Since(start).Round(time.Millisecond))
	})
}
