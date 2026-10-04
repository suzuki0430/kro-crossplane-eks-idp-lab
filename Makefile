SHELL := /bin/bash

.PHONY: tools check test graph composition cluster bootstrap platform image demo verify verify-api verify-iam failure retention cleanup
tools:
	bash scripts/install-tools.sh

check:
	cd app && test -z "$$(gofmt -l .)" && go vet ./...
	uv tool run --from shellcheck-py==0.11.0.1 shellcheck scripts/*.sh tests/*.sh
	uv tool run --from cfn-lint==1.57.1 cfn-lint infrastructure/bootstrap.yaml
	uv tool run --from ruff==0.13.3 ruff check scripts/render-evidence.py tests/test_render_evidence.py
	uv tool run --from ruff==0.13.3 ruff format --check scripts/render-evidence.py tests/test_render_evidence.py
	shasum -a 256 -c tests/crds.sha256

test:
	cd app && go test -race -cover ./...
	uv tool run --from pytest==8.4.2 pytest -q tests/test_render_evidence.py

graph:
	bash tests/local-cluster.sh

composition:
	bash tests/local-composition.sh

cluster:
	bash scripts/01-cluster.sh
bootstrap:
	bash scripts/02-bootstrap.sh
platform:
	bash scripts/03-platform.sh
image:
	bash scripts/04-image.sh
demo:
	bash scripts/05-demo.sh
verify:
	bash scripts/verify.sh
verify-api:
	bash scripts/verify-api.sh
verify-iam:
	bash scripts/verify-iam-policy.sh
failure:
	bash scripts/experiment-failure.sh
retention:
	bash scripts/experiment-retention.sh
cleanup:
	bash scripts/cleanup.sh
