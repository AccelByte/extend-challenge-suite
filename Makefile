# AccelByte Extend Challenge Suite - Makefile
# Orchestration commands for local development and testing

# ---------------------------------------------------------------------------
# Reusable macro: run an E2E test script, loading tests/e2e/.env if present
# ---------------------------------------------------------------------------
define run_e2e
	@if [ ! -f extend-challenge-demo-app/bin/challenge-demo ]; then \
		echo "Demo app binary not found — building automatically..."; \
		cd extend-challenge-demo-app && mkdir -p bin && go build -o bin/challenge-demo ./cmd/challenge-demo; \
	fi
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./$(1); \
	else \
		cd tests/e2e && ./$(1); \
	fi
endef

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo "AccelByte Extend Challenge Suite - Available Commands:"
	@echo ""
	@echo "Setup:"
	@echo "  make check-prereqs   - Verify required tools are installed"
	@echo "  make setup           - Clone all service repositories"
	@echo "  make build-demo-app  - Build the demo app for E2E testing"
	@echo "  make quickstart      - One command: clone, build, start, verify"
	@echo ""
	@echo "Development (services start in mock mode — no AGS credentials needed):"
	@echo "  make dev-up          - Start services (fastest — reuses existing images)"
	@echo "  make dev-rebuild     - Rebuild images and restart (use after Go code changes)"
	@echo "  make dev-restart     - Full rebuild from scratch, --no-cache (use if cached build seems wrong)"
	@echo "  make dev-down        - Stop all services"
	@echo "  make dev-ps          - Show running services"
	@echo "  make dev-logs        - View logs from all services"
	@echo "  make dev-clean       - Clean up volumes and containers"
	@echo "  make dev-up-loadtest      - Start services with loadtest config"
	@echo "  make dev-rebuild-loadtest - Rebuild with loadtest config"
	@echo ""
	@echo "Testing:"
	@echo "  make test-unit       - Run unit tests across all 3 projects (~30s, no DB needed)"
	@echo "  make test-integration - Run integration tests (auto DB lifecycle, ~2 min)"
	@echo "  make lint            - Run golangci-lint across all 3 projects"
	@echo "  make test-loadtest-smoke - Run load test smoke (scenario3, ~5 min)"
	@echo ""
	@echo "  make test-e2e        - Run all E2E tests (auto-loads tests/e2e/.env)"
	@echo "  make test-e2e-login  - Test login flow"
	@echo "  make test-e2e-stat   - Test stat update flow"
	@echo "  make test-e2e-daily  - Test daily goal behavior"
	@echo "  make test-e2e-buffering - Test performance & buffering"
	@echo "  make test-e2e-prereqs - Test prerequisites"
	@echo "  make test-e2e-mixed  - Test mixed goal types"
	@echo "  make test-e2e-m3-init - Test M3 player initialization"
	@echo "  make test-e2e-inactive - Test inactive goal filtering"
	@echo "  make test-e2e-m4-batch - Test M4 batch goal selection"
	@echo "  make test-e2e-m4-random - Test M4 random goal selection"
	@echo "  make test-e2e-errors - Test error scenarios"
	@echo "  make test-e2e-rewards - Test reward failures"
	@echo "  make test-e2e-multiuser - Test multi-user isolation"
	@echo ""
	@echo "  M5 Rotation Tests (21 tests):"
	@echo "  make test-e2e-m5-rotation-basic   - Quick sanity check for rotation"
	@echo "  Run 'make test-e2e-help' for the full list of individual test targets."
	@echo ""
	@echo "Note: All test targets automatically load tests/e2e/.env if present"

.PHONY: test-e2e-help
test-e2e-help:
	@echo "E2E Test Targets:"
	@echo ""
	@echo "  make test-e2e              Run all 34 E2E tests"
	@echo ""
	@echo "  Happy Path:"
	@echo "    make test-e2e-login      Login flow"
	@echo "    make test-e2e-stat       Stat update flow"
	@echo "    make test-e2e-daily      Daily goal behavior"
	@echo "    make test-e2e-buffering  Performance & buffering"
	@echo "    make test-e2e-prereqs    Prerequisites"
	@echo "    make test-e2e-mixed      Mixed goal types"
	@echo ""
	@echo "  M3 Features:"
	@echo "    make test-e2e-m3-init    Player initialization"
	@echo "    make test-e2e-inactive   Inactive goal filtering"
	@echo ""
	@echo "  M4 Features:"
	@echo "    make test-e2e-m4-batch   Batch goal selection"
	@echo "    make test-e2e-m4-random  Random goal selection"
	@echo ""
	@echo "  M5 Rotation:"
	@echo "    make test-e2e-m5-rotation-basic    Basic rotation"
	@echo "    make test-e2e-m5-rotation-reset    Progress reset"
	@echo "    make test-e2e-m5-rotation-no-reset No reset"
	@echo "    make test-e2e-m5-rotation-claimed  Claimed goals"
	@echo "    make test-e2e-m5-rotation-status   Status endpoint"
	@echo "    make test-e2e-m5-rotation-expiry   Expiry fields"
	@echo "    make test-e2e-m5-rotation-claim-guard  Claim guard"
	@echo "    make test-e2e-m5-rotation-full-cycle   Full cycle"
	@echo "    make test-e2e-m5-rotation-initialize   Initialize catch-up"
	@echo "    make test-e2e-m5-rotation-multi-period Multi-period"
	@echo "    make test-e2e-m5-rotation-login        Login rotation"
	@echo "    make test-e2e-m5-rotation-monthly     Monthly rotation"
	@echo "    make test-e2e-m5-rotation-completed-preserved Completed preserved"
	@echo "    make test-e2e-m5-rotation-expiry-on-init Expiry on init"
	@echo "    make test-e2e-m5-rotation-mixed-schedules Mixed schedules"
	@echo "    make test-e2e-m5-rotation-claim-guard-error Claim guard error"
	@echo "    make test-e2e-m5-rotation-in-progress    Partial progress reset"
	@echo "    make test-e2e-m5-rotation-absolute-coexist Rotation vs absolute"
	@echo "    make test-e2e-m5-rotation-global-sync    Global sync two users"
	@echo "    make test-e2e-m5-rotation-batch-select   M4+M5 batch select"
	@echo "    make test-e2e-m5-rotation-never-progressed Dormant player"
	@echo ""
	@echo "  Error Scenarios:"
	@echo "    make test-e2e-errors     Error scenarios"
	@echo "    make test-e2e-rewards    Reward failures"
	@echo "    make test-e2e-multiuser  Multi-user isolation"

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
.PHONY: check-prereqs
check-prereqs:
	@echo "Checking prerequisites..."
	@ok=true; \
	for cmd in docker jq make; do \
		if command -v $$cmd >/dev/null 2>&1; then \
			printf "  %-18s %s\n" "$$cmd" "$$($$cmd --version 2>/dev/null | head -1 || echo 'OK')"; \
		else \
			printf "  %-18s MISSING\n" "$$cmd"; \
			ok=false; \
		fi; \
	done; \
	if command -v go >/dev/null 2>&1; then \
		printf "  %-18s %s\n" "go" "$$(go version 2>/dev/null | head -1)"; \
	else \
		printf "  %-18s MISSING\n" "go"; \
		ok=false; \
	fi; \
	if docker compose version >/dev/null 2>&1; then \
		printf "  %-18s %s\n" "docker compose" "$$(docker compose version --short 2>/dev/null || echo 'OK')"; \
	else \
		printf "  %-18s MISSING (install Docker Compose V2)\n" "docker compose"; \
		ok=false; \
	fi; \
	if $$ok; then \
		echo ""; \
		echo "All required prerequisites satisfied."; \
	else \
		echo ""; \
		echo "Install the missing tools above before continuing."; \
		exit 1; \
	fi; \
	echo ""; \
	echo "Optional (needed for specific test types):"; \
	if command -v golangci-lint >/dev/null 2>&1; then \
		printf "  %-18s %s\n" "golangci-lint" "$$(golangci-lint --version 2>/dev/null | head -1)"; \
	else \
		printf "  %-18s not installed (needed for 'make lint')\n" "golangci-lint"; \
		echo "                     Install: https://golangci-lint.run/welcome/install/"; \
	fi; \
	if command -v k6 >/dev/null 2>&1; then \
		printf "  %-18s %s\n" "k6" "$$(k6 version 2>/dev/null | head -1)"; \
	else \
		printf "  %-18s not installed (needed for 'make test-loadtest-smoke')\n" "k6"; \
		echo "                     Install: https://grafana.com/docs/k6/latest/set-up/install-k6/"; \
	fi

# ---------------------------------------------------------------------------
# Ensure .env exists (auto-copy from .env.example on first run)
# ---------------------------------------------------------------------------
.PHONY: ensure-env
ensure-env:
	@if [ ! -f .env ] && [ -f .env.example ]; then \
		cp .env.example .env; \
		echo "Created .env from .env.example (edit to customize)."; \
	fi

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
.PHONY: setup
setup:
	@echo "Cloning service repositories..."
	@for repo in extend-challenge-common extend-challenge-service extend-challenge-event-handler extend-challenge-demo-app; do \
		if [ ! -d "$$repo" ]; then \
			echo "Cloning $$repo..."; \
			if ! git clone "https://github.com/AccelByte/$$repo.git"; then \
				echo ""; \
				echo "ERROR: Failed to clone $$repo."; \
				echo "  If this is a private repo, try SSH:"; \
				echo "    git clone git@github.com:AccelByte/$$repo.git"; \
				exit 1; \
			fi; \
		else \
			echo "$$repo already exists"; \
		fi; \
	done
	@echo ""
	@echo "Setup complete! All service repositories are ready."
	@echo "  Run 'make dev-up' to start all services."
	@echo "  Run 'make build-demo-app' to build the demo app for testing."

.PHONY: build-demo-app
build-demo-app:
	@echo "Building demo app..."
	@if [ ! -d "extend-challenge-demo-app" ]; then \
		echo "ERROR: extend-challenge-demo-app directory not found."; \
		echo "Run 'make setup' first."; \
		exit 1; \
	fi
	@cd extend-challenge-demo-app && mkdir -p bin && go build -o bin/challenge-demo ./cmd/challenge-demo
	@echo "Demo app built successfully at: extend-challenge-demo-app/bin/challenge-demo"

.PHONY: quickstart
quickstart: check-prereqs setup build-demo-app dev-up
	@echo ""
	@echo "=========================================="
	@echo "  Quickstart complete!"
	@echo "=========================================="
	@echo ""
	@echo "Smoke test:"
	@echo "  curl -s http://localhost:8000/challenge/v1/challenges -H 'Authorization: Bearer mock' | jq ."
	@echo ""
	@echo "Run all 34 E2E tests:"
	@echo "  make test-e2e"

# ---------------------------------------------------------------------------
# Development
# ---------------------------------------------------------------------------
.PHONY: dev-up
dev-up: setup ensure-env
	@echo "Starting all services..."
	docker compose up -d --wait
	@echo ""
	@echo "All services healthy and ready!"
	@echo "  - PostgreSQL:          localhost:5433"
	@echo "  - Redis:               localhost:6379"
	@echo "  - Challenge Service:   localhost:8000 (HTTP), localhost:6565 (gRPC)"
	@echo "  - Event Handler:       localhost:6566 (gRPC)"
	@echo "  - Metrics:             localhost:8080, localhost:8081"
	@echo ""
	@echo "Run 'make dev-logs' to view logs"

.PHONY: dev-rebuild
dev-rebuild: ensure-env
	@echo "Rebuilding and restarting services..."
	docker compose up -d --build --wait
	@echo ""
	@echo "Services rebuilt, healthy and ready!"

.PHONY: dev-down
dev-down:
	@echo "Stopping all services..."
	docker compose down
	@echo "Services stopped"

.PHONY: dev-restart
dev-restart: ensure-env
	@echo "Restarting all services..."
	docker compose down
	docker compose build --no-cache
	docker compose up -d --wait
	@echo "Services rebuilt from scratch, healthy and ready!"

.PHONY: dev-logs
dev-logs:
	docker compose logs -f

.PHONY: dev-ps
dev-ps:
	docker compose ps

.PHONY: dev-clean
dev-clean:
	@echo "Cleaning up Docker volumes and containers..."
	docker compose down -v
	@echo "Cleanup complete"

.PHONY: dev-up-loadtest
dev-up-loadtest: setup ensure-env
	@echo "Starting services with loadtest config..."
	docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --wait
	@echo ""
	@echo "Services started with loadtest config ($(shell jq '[.challenges[].goals[]] | length' tests/loadtest/fixtures/challenges.json 2>/dev/null || echo '?') goals)"
	@echo "  Config: tests/loadtest/fixtures/challenges.json (volume-mounted)"
	@echo "  To switch back to E2E config: make dev-up"

.PHONY: dev-rebuild-loadtest
dev-rebuild-loadtest: ensure-env
	@echo "Rebuilding services with loadtest config..."
	docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --build --wait
	@echo ""
	@echo "Services rebuilt with loadtest config"

# ---------------------------------------------------------------------------
# Unit Tests (no DB or services needed)
# ---------------------------------------------------------------------------
.PHONY: test-unit
test-unit:
	@echo "Running unit tests across all projects..."
	@echo ""
	@fail=false; \
	echo "=== extend-challenge-common ==="; \
	(cd extend-challenge-common && go test $$(go list ./... | grep -v /integration) -v) || fail=true; \
	echo ""; \
	echo "=== extend-challenge-service ==="; \
	(cd extend-challenge-service && go test $$(go list ./... | grep -v /tests/integration) -v) || fail=true; \
	echo ""; \
	echo "=== extend-challenge-event-handler ==="; \
	(cd extend-challenge-event-handler && go test $$(go list ./... | grep -v /integration) -v) || fail=true; \
	echo ""; \
	if $$fail; then \
		echo "FAIL: Some unit tests failed."; \
		exit 1; \
	fi; \
	echo "All unit tests passed."

# ---------------------------------------------------------------------------
# Integration Tests (auto DB lifecycle, no main stack needed)
# ---------------------------------------------------------------------------
.PHONY: test-integration
test-integration:
	@echo "Running integration tests across all projects..."
	@echo ""
	@if ss -tln 2>/dev/null | grep -q ':5433 ' || lsof -iTCP:5433 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "ERROR: Port 5433 is already in use (main stack running?)."; \
		echo "  Stop the main stack first: make dev-down"; \
		exit 1; \
	fi
	@fail=false; \
	echo "=== extend-challenge-service (port 5433) ==="; \
	(cd extend-challenge-service && \
		$(MAKE) test-integration-setup && \
		($(MAKE) test-integration-run || ($(MAKE) test-integration-teardown; false)) && \
		$(MAKE) test-integration-teardown \
	) || fail=true; \
	echo ""; \
	echo "=== extend-challenge-event-handler (port 5432) ==="; \
	(cd extend-challenge-event-handler && \
		$(MAKE) test-integration-setup && \
		($(MAKE) test-integration-run || ($(MAKE) test-integration-teardown; false)) && \
		$(MAKE) test-integration-teardown \
	) || fail=true; \
	echo ""; \
	echo "=== extend-challenge-common (port 5433) ==="; \
	(cd extend-challenge-common && \
		$(MAKE) db-setup && \
		($(MAKE) test || ($(MAKE) db-teardown; false)) && \
		$(MAKE) db-teardown \
	) || fail=true; \
	echo ""; \
	if $$fail; then \
		echo "FAIL: Some integration tests failed."; \
		exit 1; \
	fi; \
	echo "All integration tests passed."

# ---------------------------------------------------------------------------
# Lint (golangci-lint across all projects)
# ---------------------------------------------------------------------------
.PHONY: lint
lint:
	@if ! command -v golangci-lint >/dev/null 2>&1; then \
		echo "ERROR: golangci-lint not installed."; \
		echo "  Install: https://golangci-lint.run/welcome/install/"; \
		exit 1; \
	fi
	@echo "Running golangci-lint across all projects..."
	@echo ""
	@fail=false; \
	for dir in extend-challenge-common extend-challenge-service extend-challenge-event-handler; do \
		echo "=== $$dir ==="; \
		(cd "$$dir" && golangci-lint run ./...) || fail=true; \
		echo ""; \
	done; \
	if $$fail; then \
		echo "FAIL: Linter found issues."; \
		exit 1; \
	fi; \
	echo "All projects pass lint."

# ---------------------------------------------------------------------------
# Load Test Smoke (scenario3_smoke, ~5 min)
# ---------------------------------------------------------------------------
.PHONY: test-loadtest-smoke
test-loadtest-smoke:
	@if ! command -v k6 >/dev/null 2>&1; then \
		echo "ERROR: k6 not installed."; \
		echo "  Install: https://grafana.com/docs/k6/latest/set-up/install-k6/"; \
		exit 1; \
	fi
	@echo "Switching to loadtest config..."
	@$(MAKE) dev-up-loadtest
	@echo ""
	@echo "Running scenario3_smoke (~5 min)..."
	@cd tests/loadtest && k6 run k6/scenario3_smoke.js; smoke_exit=$$?; \
	echo ""; \
	echo "Switching back to E2E config..."; \
	cd ../.. && $(MAKE) dev-up; \
	exit $$smoke_exit

# ---------------------------------------------------------------------------
# E2E Tests (all targets use the run_e2e macro)
# ---------------------------------------------------------------------------
.PHONY: test-e2e
test-e2e:
	@if [ ! -f extend-challenge-demo-app/bin/challenge-demo ]; then \
		echo "Demo app binary not found — building automatically..."; \
		cd extend-challenge-demo-app && mkdir -p bin && go build -o bin/challenge-demo ./cmd/challenge-demo; \
	fi
	@echo "Running all E2E tests..."
	@if [ -f tests/e2e/.env ]; then \
		echo "Loading environment from tests/e2e/.env..."; \
		cd tests/e2e && set -a && . ./.env && set +a && ./run-all-tests.sh; \
	else \
		echo "No .env found -- running in mock mode (no credentials needed)."; \
		echo "   For real AGS testing: cp tests/e2e/.env.example tests/e2e/.env"; \
		cd tests/e2e && ./run-all-tests.sh; \
	fi

# Happy path
.PHONY: test-e2e-login
test-e2e-login:
	$(call run_e2e,test-login-flow.sh)

.PHONY: test-e2e-stat
test-e2e-stat:
	$(call run_e2e,test-stat-flow.sh)

.PHONY: test-e2e-daily
test-e2e-daily:
	$(call run_e2e,test-daily-goal.sh)

.PHONY: test-e2e-buffering
test-e2e-buffering:
	$(call run_e2e,test-buffering-performance.sh)

.PHONY: test-e2e-prereqs
test-e2e-prereqs:
	$(call run_e2e,test-prerequisites.sh)

.PHONY: test-e2e-mixed
test-e2e-mixed:
	$(call run_e2e,test-mixed-goals.sh)

# Error scenarios
.PHONY: test-e2e-errors
test-e2e-errors:
	$(call run_e2e,test-error-scenarios.sh)

.PHONY: test-e2e-rewards
test-e2e-rewards:
	$(call run_e2e,test-reward-failures.sh)

.PHONY: test-e2e-multiuser
test-e2e-multiuser:
	$(call run_e2e,test-multi-user.sh)

# M3 features
.PHONY: test-e2e-m3-init
test-e2e-m3-init:
	$(call run_e2e,test-m3-initialization.sh)

.PHONY: test-e2e-inactive
test-e2e-inactive:
	$(call run_e2e,test-inactive-goal-filtering.sh)

# M4 features
.PHONY: test-e2e-m4-batch
test-e2e-m4-batch:
	$(call run_e2e,test-m4-batch-selection.sh)

.PHONY: test-e2e-m4-random
test-e2e-m4-random:
	$(call run_e2e,test-m4-random-selection.sh)

# M5 rotation
.PHONY: test-e2e-m5-rotation-basic
test-e2e-m5-rotation-basic:
	$(call run_e2e,test-m5-rotation-basic.sh)

.PHONY: test-e2e-m5-rotation-reset
test-e2e-m5-rotation-reset:
	$(call run_e2e,test-m5-rotation-reset.sh)

.PHONY: test-e2e-m5-rotation-no-reset
test-e2e-m5-rotation-no-reset:
	$(call run_e2e,test-m5-rotation-no-reset.sh)

.PHONY: test-e2e-m5-rotation-claimed
test-e2e-m5-rotation-claimed:
	$(call run_e2e,test-m5-rotation-claimed.sh)

.PHONY: test-e2e-m5-rotation-status
test-e2e-m5-rotation-status:
	$(call run_e2e,test-m5-rotation-status.sh)

.PHONY: test-e2e-m5-rotation-expiry
test-e2e-m5-rotation-expiry:
	$(call run_e2e,test-m5-rotation-expiry-fields.sh)

.PHONY: test-e2e-m5-rotation-claim-guard
test-e2e-m5-rotation-claim-guard:
	$(call run_e2e,test-m5-rotation-claim-guard.sh)

.PHONY: test-e2e-m5-rotation-full-cycle
test-e2e-m5-rotation-full-cycle:
	$(call run_e2e,test-m5-rotation-full-cycle.sh)

.PHONY: test-e2e-m5-rotation-initialize
test-e2e-m5-rotation-initialize:
	$(call run_e2e,test-m5-rotation-initialize.sh)

.PHONY: test-e2e-m5-rotation-multi-period
test-e2e-m5-rotation-multi-period:
	$(call run_e2e,test-m5-rotation-multi-period.sh)

.PHONY: test-e2e-m5-rotation-login
test-e2e-m5-rotation-login:
	$(call run_e2e,test-m5-rotation-login.sh)

.PHONY: test-e2e-m5-rotation-monthly
test-e2e-m5-rotation-monthly:
	$(call run_e2e,test-m5-rotation-monthly.sh)

.PHONY: test-e2e-m5-rotation-completed-preserved
test-e2e-m5-rotation-completed-preserved:
	$(call run_e2e,test-m5-rotation-completed-preserved.sh)

.PHONY: test-e2e-m5-rotation-expiry-on-init
test-e2e-m5-rotation-expiry-on-init:
	$(call run_e2e,test-m5-rotation-expiry-on-init.sh)

.PHONY: test-e2e-m5-rotation-mixed-schedules
test-e2e-m5-rotation-mixed-schedules:
	$(call run_e2e,test-m5-rotation-mixed-schedules.sh)

.PHONY: test-e2e-m5-rotation-claim-guard-error
test-e2e-m5-rotation-claim-guard-error:
	$(call run_e2e,test-m5-rotation-claim-guard-error.sh)

.PHONY: test-e2e-m5-rotation-in-progress
test-e2e-m5-rotation-in-progress:
	$(call run_e2e,test-m5-rotation-in-progress.sh)

.PHONY: test-e2e-m5-rotation-absolute-coexist
test-e2e-m5-rotation-absolute-coexist:
	$(call run_e2e,test-m5-rotation-absolute-coexist.sh)

.PHONY: test-e2e-m5-rotation-global-sync
test-e2e-m5-rotation-global-sync:
	$(call run_e2e,test-m5-rotation-global-sync.sh)

.PHONY: test-e2e-m5-rotation-batch-select
test-e2e-m5-rotation-batch-select:
	$(call run_e2e,test-m5-rotation-batch-select.sh)

.PHONY: test-e2e-m5-rotation-never-progressed
test-e2e-m5-rotation-never-progressed:
	$(call run_e2e,test-m5-rotation-never-progressed.sh)
