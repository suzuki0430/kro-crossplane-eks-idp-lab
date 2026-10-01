package api

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeStore struct {
	body   []byte
	err    error
	puts   int
	checks int
}

// Put records the payload to assert that invalid input never reaches storage.
func (s *fakeStore) Put(_ context.Context, _ string, body []byte) error {
	s.puts++
	s.body = bytes.Clone(body)
	return s.err
}

// Get returns a configured value or storage failure.
func (s *fakeStore) Get(context.Context, string) ([]byte, error) { return s.body, s.err }

// Check tracks readiness independently from liveness.
func (s *fakeStore) Check(context.Context) error { s.checks++; return s.err }

// TestRoundTrip verifies binary preservation, size bounds, and response headers.
func TestRoundTrip(t *testing.T) {
	s := &fakeStore{}
	h := NewHandler(s, slog.New(slog.NewTextHandler(io.Discard, nil)))
	body := []byte{0, 255, 1, 2, 10}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPut, "/objects/a.bin", bytes.NewReader(body)))
	if w.Code != http.StatusNoContent || s.puts != 1 {
		t.Fatalf("PUT: %d, calls %d", w.Code, s.puts)
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/objects/a.bin", nil))
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), body) {
		t.Fatalf("GET: %d, %q", w.Code, w.Body.Bytes())
	}
	if w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("missing nosniff")
	}
}

// TestFailures checks API boundaries, missing keys, and opaque backend errors.
func TestFailures(t *testing.T) {
	for _, tc := range []struct {
		name, method, path, body string
		err                      error
		want                     int
		writes                   int
	}{
		{"too large", "PUT", "/objects/test", strings.Repeat("x", int(MaxObjectBytes)+1), nil, 413, 0},
		{"invalid key", "PUT", "/objects/%3Cscript%3E", "hello", nil, 400, 0},
		{"long key", "PUT", "/objects/" + strings.Repeat("x", 129), "hello", nil, 400, 0},
		{"missing", "GET", "/objects/missing", "", ErrNotFound, 404, 0},
		{"read failure", "GET", "/objects/test", "", errors.New("private AWS detail"), 503, 0},
		{"write failure", "PUT", "/objects/test", "hello", errors.New("private AWS detail"), 503, 1},
		{"unsupported method", "DELETE", "/objects/test", "", nil, 405, 0},
		{"empty object", "PUT", "/objects/test", "", nil, 204, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &fakeStore{err: tc.err}
			h := NewHandler(s, slog.New(slog.NewTextHandler(io.Discard, nil)))
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			if w.Code != tc.want || s.puts != tc.writes {
				t.Fatalf("status %d / writes %d", w.Code, s.puts)
			}
			if strings.Contains(w.Body.String(), "private AWS") {
				t.Fatal("leaked backend error")
			}
		})
	}
}

// TestReadinessDoesNotAffectLiveness prevents AWS failures from restarting healthy processes.
func TestReadinessDoesNotAffectLiveness(t *testing.T) {
	s := &fakeStore{err: errors.New("denied")}
	h := NewHandler(s, slog.New(slog.NewTextHandler(io.Discard, nil)))
	for _, tc := range []struct {
		path string
		want int
	}{{"/healthz", 200}, {"/readyz", 503}} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", tc.path, nil))
		if w.Code != tc.want {
			t.Fatalf("%s: %d", tc.path, w.Code)
		}
	}
	if s.checks != 1 {
		t.Fatalf("storage checked %d times", s.checks)
	}
}
