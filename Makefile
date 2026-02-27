# AccelByte Extend Challenge Suite - Makefile
# Orchestration commands for local development and testing

.PHONY: help
help:
	@echo "AccelByte Extend Challenge Suite - Available Commands:"
	@echo ""
	@echo "Setup:"
	@echo "  make setup           - Clone all service repositories"
	@echo "  make build-demo-app  - Build the demo app for E2E testing"
	@echo ""
	@echo "Development:"
	@echo "  make dev-up          - Start services (uses existing images)"
	@echo "  make dev-rebuild     - Rebuild images and restart (after code changes)"
	@echo "  make dev-restart     - Full rebuild from scratch (--no-cache)"
	@echo "  make dev-down        - Stop all services"
	@echo "  make dev-logs        - View logs from all services"
	@echo "  make dev-clean       - Clean up volumes and containers"
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
	@echo "  M5 Rotation Tests:"
	@echo "  make test-e2e-m5-rotation-basic   - Test basic rotation mechanics"
	@echo "  make test-e2e-m5-rotation-reset   - Test rotation progress reset"
	@echo "  make test-e2e-m5-rotation-no-reset - Test rotation without reset"
	@echo "  make test-e2e-m5-rotation-claimed - Test claimed goal rotation"
	@echo "  make test-e2e-m5-rotation-status  - Test rotation status endpoint"
	@echo "  make test-e2e-m5-rotation-expiry  - Test rotation expiry fields"
	@echo "  make test-e2e-m5-rotation-claim-guard  - Test claim-after-rotation guard"
	@echo "  make test-e2e-m5-rotation-full-cycle   - Test full rotation cycle"
	@echo "  make test-e2e-m5-rotation-initialize   - Test returning player catch-up"
	@echo "  make test-e2e-m5-rotation-multi-period - Test multiple missed periods"
	@echo "  make test-e2e-m5-rotation-login        - Test login events with rotation"
	@echo "  make test-e2e-m5-rotation-monthly      - Test monthly rotation schedule"
	@echo "  make test-e2e-m5-rotation-completed-preserved - Test completed preserved (no reset)"
	@echo "  make test-e2e-m5-rotation-expiry-on-init - Test expiry set at initialization"
	@echo "  make test-e2e-m5-rotation-mixed-schedules - Test mixed daily+weekly expiry"
	@echo "  make test-e2e-m5-rotation-claim-guard-error - Test claim guard error response"
	@echo ""
	@echo "Note: All test targets automatically load tests/e2e/.env if present"

.PHONY: test-e2e-help
test-e2e-help:
	@echo "E2E Test Targets:"
	@echo ""
	@echo "  make test-e2e              Run all 29 E2E tests"
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
	@echo ""
	@echo "  Error Scenarios:"
	@echo "    make test-e2e-errors     Error scenarios"
	@echo "    make test-e2e-rewards    Reward failures"
	@echo "    make test-e2e-multiuser  Multi-user isolation"

.PHONY: setup
setup:
	@echo "Cloning service repositories..."
	@if [ ! -d "extend-challenge-common" ]; then \
		echo "Cloning extend-challenge-common..."; \
		git clone https://github.com/AccelByte/extend-challenge-common.git; \
	else \
		echo "✓ extend-challenge-common already exists"; \
	fi
	@if [ ! -d "extend-challenge-service" ]; then \
		echo "Cloning extend-challenge-service..."; \
		git clone https://github.com/AccelByte/extend-challenge-service.git; \
	else \
		echo "✓ extend-challenge-service already exists"; \
	fi
	@if [ ! -d "extend-challenge-event-handler" ]; then \
		echo "Cloning extend-challenge-event-handler..."; \
		git clone https://github.com/AccelByte/extend-challenge-event-handler.git; \
	else \
		echo "✓ extend-challenge-event-handler already exists"; \
	fi
	@if [ ! -d "extend-challenge-demo-app" ]; then \
		echo "Cloning extend-challenge-demo-app..."; \
		git clone https://github.com/AccelByte/extend-challenge-demo-app.git; \
	else \
		echo "✓ extend-challenge-demo-app already exists"; \
	fi
	@echo ""
	@echo "✓ Setup complete! All service repositories are ready."
	@echo "  Run 'make dev-up' to start all services."
	@echo "  Run 'make build-demo-app' to build the demo app for testing."

.PHONY: build-demo-app
build-demo-app:
	@echo "Building demo app..."
	@if [ ! -d "extend-challenge-demo-app" ]; then \
		echo "❌ ERROR: extend-challenge-demo-app directory not found."; \
		echo "Run 'make setup' first."; \
		exit 1; \
	fi
	@cd extend-challenge-demo-app && mkdir -p bin && go build -o bin/challenge-demo ./cmd/challenge-demo
	@echo "✓ Demo app built successfully at: extend-challenge-demo-app/bin/challenge-demo"

.PHONY: dev-up
dev-up: setup
	@echo "Starting all services..."
	docker-compose up -d
	@echo ""
	@echo "✓ Services started!"
	@echo "  - PostgreSQL:          localhost:5433"
	@echo "  - Redis:               localhost:6379"
	@echo "  - Challenge Service:   localhost:8000 (HTTP), localhost:6565 (gRPC)"
	@echo "  - Event Handler:       localhost:6566 (gRPC)"
	@echo "  - Metrics:             localhost:8080, localhost:8081"
	@echo ""
	@echo "Run 'make dev-logs' to view logs"

.PHONY: dev-rebuild
dev-rebuild:
	@echo "Rebuilding and restarting services..."
	docker-compose up -d --build
	@echo ""
	@echo "✓ Services rebuilt and restarted"

.PHONY: dev-down
dev-down:
	@echo "Stopping all services..."
	docker-compose down
	@echo "✓ Services stopped"

.PHONY: dev-restart
dev-restart:
	@echo "Restarting all services..."
	docker-compose down
	docker-compose build --no-cache
	docker-compose up -d
	@echo "✓ Services restarted"

.PHONY: dev-logs
dev-logs:
	docker-compose logs -f

.PHONY: dev-clean
dev-clean:
	@echo "Cleaning up Docker volumes and containers..."
	docker-compose down -v
	@echo "✓ Cleanup complete"

# E2E Tests
# All test targets automatically load tests/e2e/.env if it exists
.PHONY: test-e2e
test-e2e:
	@echo "Running all E2E tests..."
	@if [ -f tests/e2e/.env ]; then \
		echo "Loading environment from tests/e2e/.env..."; \
		cd tests/e2e && set -a && . ./.env && set +a && ./run-all-tests.sh; \
	else \
		echo "ℹ️  No .env found — running in mock mode (no credentials needed)."; \
		echo "   For real AGS testing: cp tests/e2e/.env.example tests/e2e/.env"; \
		cd tests/e2e && ./run-all-tests.sh; \
	fi

.PHONY: test-e2e-login
test-e2e-login:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-login-flow.sh; \
	else \
		cd tests/e2e && ./test-login-flow.sh; \
	fi

.PHONY: test-e2e-stat
test-e2e-stat:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-stat-flow.sh; \
	else \
		cd tests/e2e && ./test-stat-flow.sh; \
	fi

.PHONY: test-e2e-daily
test-e2e-daily:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-daily-goal.sh; \
	else \
		cd tests/e2e && ./test-daily-goal.sh; \
	fi

.PHONY: test-e2e-buffering
test-e2e-buffering:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-buffering-performance.sh; \
	else \
		cd tests/e2e && ./test-buffering-performance.sh; \
	fi

.PHONY: test-e2e-prereqs
test-e2e-prereqs:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-prerequisites.sh; \
	else \
		cd tests/e2e && ./test-prerequisites.sh; \
	fi

.PHONY: test-e2e-mixed
test-e2e-mixed:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-mixed-goals.sh; \
	else \
		cd tests/e2e && ./test-mixed-goals.sh; \
	fi

.PHONY: test-e2e-errors
test-e2e-errors:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-error-scenarios.sh; \
	else \
		cd tests/e2e && ./test-error-scenarios.sh; \
	fi

.PHONY: test-e2e-rewards
test-e2e-rewards:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-reward-failures.sh; \
	else \
		cd tests/e2e && ./test-reward-failures.sh; \
	fi

.PHONY: test-e2e-multiuser
test-e2e-multiuser:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-multi-user.sh; \
	else \
		cd tests/e2e && ./test-multi-user.sh; \
	fi

.PHONY: test-e2e-m3-init
test-e2e-m3-init:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m3-initialization.sh; \
	else \
		cd tests/e2e && ./test-m3-initialization.sh; \
	fi

.PHONY: test-e2e-inactive
test-e2e-inactive:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-inactive-goal-filtering.sh; \
	else \
		cd tests/e2e && ./test-inactive-goal-filtering.sh; \
	fi
.PHONY: test-e2e-m4-batch
test-e2e-m4-batch:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m4-batch-selection.sh; \
	else \
		cd tests/e2e && ./test-m4-batch-selection.sh; \
	fi

.PHONY: test-e2e-m4-random
test-e2e-m4-random:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m4-random-selection.sh; \
	else \
		cd tests/e2e && ./test-m4-random-selection.sh; \
	fi

.PHONY: test-e2e-m5-rotation-basic
test-e2e-m5-rotation-basic:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-basic.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-basic.sh; \
	fi

.PHONY: test-e2e-m5-rotation-reset
test-e2e-m5-rotation-reset:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-reset.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-reset.sh; \
	fi

.PHONY: test-e2e-m5-rotation-no-reset
test-e2e-m5-rotation-no-reset:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-no-reset.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-no-reset.sh; \
	fi

.PHONY: test-e2e-m5-rotation-claimed
test-e2e-m5-rotation-claimed:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-claimed.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-claimed.sh; \
	fi

.PHONY: test-e2e-m5-rotation-status
test-e2e-m5-rotation-status:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-status.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-status.sh; \
	fi

.PHONY: test-e2e-m5-rotation-expiry
test-e2e-m5-rotation-expiry:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-expiry-fields.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-expiry-fields.sh; \
	fi

.PHONY: test-e2e-m5-rotation-claim-guard
test-e2e-m5-rotation-claim-guard:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-claim-guard.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-claim-guard.sh; \
	fi

.PHONY: test-e2e-m5-rotation-full-cycle
test-e2e-m5-rotation-full-cycle:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-full-cycle.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-full-cycle.sh; \
	fi

.PHONY: test-e2e-m5-rotation-initialize
test-e2e-m5-rotation-initialize:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-initialize.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-initialize.sh; \
	fi

.PHONY: test-e2e-m5-rotation-multi-period
test-e2e-m5-rotation-multi-period:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-multi-period.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-multi-period.sh; \
	fi

.PHONY: test-e2e-m5-rotation-login
test-e2e-m5-rotation-login:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-login.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-login.sh; \
	fi

.PHONY: test-e2e-m5-rotation-monthly
test-e2e-m5-rotation-monthly:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-monthly.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-monthly.sh; \
	fi

.PHONY: test-e2e-m5-rotation-completed-preserved
test-e2e-m5-rotation-completed-preserved:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-completed-preserved.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-completed-preserved.sh; \
	fi

.PHONY: test-e2e-m5-rotation-expiry-on-init
test-e2e-m5-rotation-expiry-on-init:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-expiry-on-init.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-expiry-on-init.sh; \
	fi

.PHONY: test-e2e-m5-rotation-mixed-schedules
test-e2e-m5-rotation-mixed-schedules:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-mixed-schedules.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-mixed-schedules.sh; \
	fi

.PHONY: test-e2e-m5-rotation-claim-guard-error
test-e2e-m5-rotation-claim-guard-error:
	@if [ -f tests/e2e/.env ]; then \
		cd tests/e2e && set -a && . ./.env && set +a && ./test-m5-rotation-claim-guard-error.sh; \
	else \
		cd tests/e2e && ./test-m5-rotation-claim-guard-error.sh; \
	fi
