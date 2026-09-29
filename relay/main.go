package main

import (
	"context"
	"errors"
	"fmt"
	"log"
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

	server := &http.Server{
		Addr:              addr,
		Handler:           logRequests(NewRelay(cfg)),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()

	access := "open registration"
	if cfg.AccessToken != "" {
		access = "access token required"
	}
	log.Printf("mobdev relay listening on %s (%s)", addr, access)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
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
		if r.URL.Path == "/v1/host/poll" && recorder.status != http.StatusOK && recorder.status < 400 {
			return // Idle and closed long polls are noise.
		}
		status := "closed"
		if recorder.status != 0 {
			status = fmt.Sprintf("%d %s", recorder.status, http.StatusText(recorder.status))
		}
		log.Printf("%s %s %s %s", r.Method, r.URL.Path, status, time.Since(start).Round(time.Millisecond))
	})
}
