package storage

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
	"github.com/suzuki0430/kro-crossplane-eks-idp-lab/app/internal/api"
)

type fakeS3 struct {
	body                      string
	putKey, getKey, deleteKey string
	putErr, getErr, deleteErr error
}

// PutObject records the exact key and optionally fails without storing anything.
func (f *fakeS3) PutObject(_ context.Context, in *s3.PutObjectInput, _ ...func(*s3.Options)) (*s3.PutObjectOutput, error) {
	f.putKey = *in.Key
	return &s3.PutObjectOutput{}, f.putErr
}

// GetObject returns the configured bounded test response.
func (f *fakeS3) GetObject(_ context.Context, in *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	f.getKey = *in.Key
	return &s3.GetObjectOutput{Body: io.NopCloser(strings.NewReader(f.body))}, f.getErr
}

// DeleteObject records cleanup so failed readiness does not silently leak sentinels.
func (f *fakeS3) DeleteObject(_ context.Context, in *s3.DeleteObjectInput, _ ...func(*s3.Options)) (*s3.DeleteObjectOutput, error) {
	f.deleteKey = *in.Key
	return &s3.DeleteObjectOutput{}, f.deleteErr
}

// TestProbe verifies permission failures, content comparison, and cleanup on error.
func TestProbe(t *testing.T) {
	for _, tc := range []struct {
		name, body                string
		putErr, getErr, deleteErr error
		fail, cleanup             bool
	}{
		{"ready", "storage-app-ready\n", nil, nil, nil, false, true},
		{"put denied", "", errors.New("denied"), nil, nil, true, false},
		{"get denied", "", nil, errors.New("denied"), nil, true, true},
		{"mismatch", "wrong", nil, nil, nil, true, true},
		{"delete denied", "storage-app-ready\n", nil, nil, errors.New("denied"), true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeS3{body: tc.body, putErr: tc.putErr, getErr: tc.getErr, deleteErr: tc.deleteErr}
			err := New(f, "bucket", "pod-123").Check(context.Background())
			if (err != nil) != tc.fail {
				t.Fatalf("error: %v", err)
			}
			if (f.deleteKey != "") != tc.cleanup {
				t.Fatalf("cleanup: %q", f.deleteKey)
			}
			if f.putKey != "_health/pod-123" {
				t.Fatalf("unsafe health key: %q", f.putKey)
			}
		})
	}
}

// TestUserObjectsStayUnderUploads prevents API callers from reaching health sentinels.
func TestUserObjectsStayUnderUploads(t *testing.T) {
	f := &fakeS3{body: "hello"}
	s := New(f, "bucket", "pod")
	if err := s.Put(context.Background(), "file", []byte("hello")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(context.Background(), "file"); err != nil {
		t.Fatal(err)
	}
	if f.putKey != "uploads/file" || f.getKey != "uploads/file" {
		t.Fatal("wrong prefix")
	}
}

// TestMissingAndOversizedObjects checks error mapping and memory bounds on external data.
func TestMissingAndOversizedObjects(t *testing.T) {
	f := &fakeS3{getErr: &smithy.GenericAPIError{Code: "NoSuchKey"}}
	if _, err := New(f, "bucket", "pod").Get(context.Background(), "missing"); !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("missing: %v", err)
	}
	f.getErr = nil
	f.body = strings.Repeat("x", int(api.MaxObjectBytes)+1)
	if _, err := New(f, "bucket", "pod").Get(context.Background(), "large"); err == nil {
		t.Fatal("unbounded read")
	}
}
