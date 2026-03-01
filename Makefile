# AccelByte Extend Challenge Suite - Makefile
# Orchestration commands for local development and testing

# ---------------------------------------------------------------------------
# Reusable macro: run an E2E test script, loading tests/e2e/.env if present
# ---------------------------------------------------------------------------
define run_e2e
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
		echo "All prerequisites satisfied."; \
	else \
		echo ""; \
		echo "Install the missing tools above before continuing."; \
		exit 1; \
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
	@if [ ! -d "extend-challenge-common" ]; then \
		echo "Cloning extend-challenge-common..."; \
		git clone https://github.com/AccelByte/extend-challenge-common.git; \
	else \
		echo "extend-challenge-common already exists"; \
	fi
	@if [ ! -d "extend-challenge-service" ]; then \
		echo "Cloning extend-challenge-service..."; \
		git clone https://github.com/AccelByte/extend-challenge-service.git; \
	else \
		echo "extend-challenge-service already exists"; \
	fi
	@if [ ! -d "extend-challenge-event-handler" ]; then \
		echo "Cloning extend-challenge-event-handler..."; \
		git clone https://github.com/AccelByte/extend-challenge-event-handler.git; \
	else \
		echo "extend-challenge-event-handler already exists"; \
	fi
	@if [ ! -d "extend-challenge-demo-app" ]; then \
		echo "Cloning extend-challenge-demo-app..."; \
		git clone https://github.com/AccelByte/extend-challenge-demo-app.git; \
	else \
		echo "extend-challenge-demo-app already exists"; \
	fi
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

# ---------------------------------------------------------------------------
# Development
# ---------------------------------------------------------------------------
.PHONY: dev-up
dev-up: setup ensure-env
	@echo "Starting all services..."
	docker compose up -d
	@echo ""
	@echo "Services started!"
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
	docker compose up -d --build
	@echo ""
	@echo "Services rebuilt and restarted"

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
	docker compose up -d
	@echo "Services restarted"

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
	docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d
	@echo ""
	@echo "Services started with loadtest config ($(shell jq '[.challenges[].goals[]] | length' tests/loadtest/fixtures/challenges.json 2>/dev/null || echo '?') goals)"
	@echo "  Config: tests/loadtest/fixtures/challenges.json (volume-mounted)"
	@echo "  To switch back to E2E config: make dev-up"

.PHONY: dev-rebuild-loadtest
dev-rebuild-loadtest: ensure-env
	@echo "Rebuilding services with loadtest config..."
	docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --build
	@echo ""
	@echo "Services rebuilt with loadtest config"

# ---------------------------------------------------------------------------
# E2E Tests (all targets use the run_e2e macro)
# ---------------------------------------------------------------------------
.PHONY: test-e2e
test-e2e:
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
