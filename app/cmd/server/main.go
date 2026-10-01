// Command server runs the cluster-internal upload API on port 8080.
// Example: AWS_REGION=ap-northeast-1 S3_BUCKET=my-bucket HOSTNAME=local go run ./cmd/server
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/suzuki0430/kro-crossplane-eks-idp-lab/app/internal/api"
	"github.com/suzuki0430/kro-crossplane-eks-idp-lab/app/internal/storage"
)

// main translates startup and shutdown failures into a nonzero process exit code.
func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

// run loads the AWS default credential chain (EKS Pod Identity in the cluster),
// starts a bounded HTTP server, and drains requests on SIGTERM.
func run(logger *slog.Logger) error {
	bucket, region, instance := os.Getenv("S3_BUCKET"), os.Getenv("AWS_REGION"), os.Getenv("HOSTNAME")
	if bucket == "" || region == "" || instance == "" {
		return errors.New("S3_BUCKET, AWS_REGION and HOSTNAME are required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region), config.WithRetryMaxAttempts(2))
	if err != nil {
		return fmt.Errorf("load AWS configuration: %w", err)
	}
	server := &http.Server{
		Addr: ":8080", Handler: api.NewHandler(storage.New(s3.NewFromConfig(cfg), bucket, instance), logger),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 15 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.ListenAndServe() }()
	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdownCtx)
	}
}
