// Package storage implements the object API using short-lived AWS credentials.
package storage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
	"github.com/suzuki0430/kro-crossplane-eks-idp-lab/app/internal/api"
)

// Client is the subset of the AWS SDK used by Store, including health-object cleanup.
// Example: *s3.Client implements it without a wrapper.
type Client interface {
	PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error)
	GetObject(context.Context, *s3.GetObjectInput, ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	DeleteObject(context.Context, *s3.DeleteObjectInput, ...func(*s3.Options)) (*s3.DeleteObjectOutput, error)
}

// Store keeps customer data under uploads/ and readiness probes under _health/.
// Its bucket and health key are immutable after construction.
type Store struct {
	client    Client
	bucket    string
	healthKey string
	checkMu   sync.Mutex
}

// New constructs an S3 store. instance must uniquely identify a running Pod.
// Example: New(client, "idplab-123-example-demo", os.Getenv("HOSTNAME")).
func New(client Client, bucket, instance string) *Store {
	return &Store{client: client, bucket: bucket, healthKey: "_health/" + instance}
}

// Put writes an object under uploads/. The HTTP layer enforces the size limit.
// Example: Put(ctx, "hello.txt", []byte("hello")) stores uploads/hello.txt.
func (s *Store) Put(ctx context.Context, key string, body []byte) error {
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String("uploads/" + key),
		Body: bytes.NewReader(body), ContentType: aws.String("application/octet-stream"),
	})
	if err != nil {
		return fmt.Errorf("put object: %w", err)
	}
	return nil
}

// Get reads at most the configured upload limit and maps missing keys to ErrNotFound.
// Example: Get(ctx, "hello.txt") reads uploads/hello.txt.
func (s *Store) Get(ctx context.Context, key string) ([]byte, error) {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String("uploads/" + key),
	})
	if err != nil {
		var awsError smithy.APIError
		if errors.As(err, &awsError) && awsError.ErrorCode() == "NoSuchKey" {
			return nil, api.ErrNotFound
		}
		return nil, fmt.Errorf("get object: %w", err)
	}
	return readBounded(out.Body, api.MaxObjectBytes)
}

// Check verifies actual Put/Get/Delete access using a Pod-specific temporary object.
// Data is compared and removed before reporting success. Customer objects are untouched.
// Example: a missing PutObject permission causes /readyz to return HTTP 503.
func (s *Store) Check(ctx context.Context) error {
	s.checkMu.Lock()
	defer s.checkMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	expected := []byte("storage-app-ready\n")
	if _, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(s.healthKey), Body: bytes.NewReader(expected),
	}); err != nil {
		return fmt.Errorf("readiness put: %w", err)
	}
	// Cleanup is attempted even if Get or comparison fails; no user-data delete is granted.
	probeErr := s.readProbe(ctx, expected)
	_, deleteErr := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(s.healthKey),
	})
	if deleteErr != nil {
		deleteErr = fmt.Errorf("readiness cleanup: %w", deleteErr)
	}
	return errors.Join(probeErr, deleteErr)
}

// readProbe checks the round trip after Check writes its sentinel; mismatches fail readiness.
func (s *Store) readProbe(ctx context.Context, expected []byte) error {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(s.healthKey)})
	if err != nil {
		return fmt.Errorf("readiness get: %w", err)
	}
	actual, err := readBounded(out.Body, 256)
	if err != nil {
		return err
	}
	if !bytes.Equal(actual, expected) {
		return errors.New("readiness round-trip mismatch")
	}
	return nil
}

// readBounded closes an SDK response and rejects oversized or truncated reads.
func readBounded(body io.ReadCloser, limit int64) (data []byte, err error) {
	defer func() { err = errors.Join(err, body.Close()) }()
	data, err = io.ReadAll(io.LimitReader(body, limit+1))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if int64(len(data)) > limit {
		return nil, errors.New("stored object exceeds size limit")
	}
	return data, nil
}
