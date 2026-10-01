// Package api serves a small, cluster-internal object API for the IDP lab.
package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"time"
)

// MaxObjectBytes caps memory and S3 request sizes. Example: a 1 MiB upload is valid.
const MaxObjectBytes int64 = 1 << 20

// ErrNotFound lets storage adapters report a missing object without exposing AWS errors.
var ErrNotFound = errors.New("object not found")

var validKey = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// Store is the bounded object storage contract. All methods must honor cancellation.
// Example: an S3 adapter or an in-memory test double can back NewHandler.
type Store interface {
	Put(context.Context, string, []byte) error
	Get(context.Context, string) ([]byte, error)
	Check(context.Context) error
}

// NewHandler builds the API with dependency-aware readiness and independent liveness.
// PUT /objects/note stores a raw body; GET /objects/note returns it as binary data.
// The service has no end-user authentication and must remain cluster-internal.
func NewHandler(store Store, logger *slog.Logger) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
		defer cancel()
		if err := store.Check(ctx); err != nil {
			logger.Warn("storage readiness failed", "error", err)
			http.Error(w, "storage is not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("PUT /objects/{key}", func(w http.ResponseWriter, r *http.Request) {
		key := r.PathValue("key")
		if !validKey.MatchString(key) {
			http.Error(w, "invalid object key", http.StatusBadRequest)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, MaxObjectBytes)
		body, err := io.ReadAll(r.Body)
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				http.Error(w, "object exceeds 1 MiB", http.StatusRequestEntityTooLarge)
			} else {
				http.Error(w, "could not read request", http.StatusBadRequest)
			}
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		if err := store.Put(ctx, key, body); err != nil {
			logger.Error("object write failed", "error", err)
			http.Error(w, "storage unavailable", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /objects/{key}", func(w http.ResponseWriter, r *http.Request) {
		key := r.PathValue("key")
		if !validKey.MatchString(key) {
			http.Error(w, "invalid object key", http.StatusBadRequest)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		body, err := store.Get(ctx, key)
		if errors.Is(err, ErrNotFound) {
			http.Error(w, "object not found", http.StatusNotFound)
			return
		}
		if err != nil {
			logger.Error("object read failed", "error", err)
			http.Error(w, "storage unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", "attachment")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if _, err := w.Write(body); err != nil {
			logger.Debug("client response interrupted", "error", err)
		}
	})
	return mux
}
