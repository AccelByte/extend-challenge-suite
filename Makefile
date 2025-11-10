# AccelByte Extend Challenge Suite - Makefile
# Orchestration commands for local development and testing

.PHONY: help
help:
	@echo "AccelByte Extend Challenge Suite - Available Commands:"
	@echo ""
	@echo "Setup:"
	@echo "  make setup           - Clone all service repositories"
	@echo ""
	@echo "Development:"
	@echo "  make dev-up          - Start all services (postgres, redis, services)"
	@echo "  make dev-down        - Stop all services"
	@echo "  make dev-restart     - Restart all services"
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
	@echo "  make test-e2e-errors - Test error scenarios"
	@echo "  make test-e2e-rewards - Test reward failures"
	@echo "  make test-e2e-multiuser - Test multi-user isolation"
	@echo ""
	@echo "Note: All test targets automatically load tests/e2e/.env if present"

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

.PHONY: dev-up
dev-up: setup
	@echo "Starting all services..."
	docker-compose up -d
	@echo ""
	@echo "✓ Services started!"
	@echo "  - PostgreSQL:          localhost:5432"
	@echo "  - Redis:               localhost:6379"
	@echo "  - Challenge Service:   localhost:8000 (HTTP), localhost:6565 (gRPC)"
	@echo "  - Event Handler:       localhost:6566 (gRPC)"
	@echo "  - Metrics:             localhost:8080, localhost:8081"
	@echo ""
	@echo "Run 'make dev-logs' to view logs"

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
		echo "⚠️  Warning: tests/e2e/.env not found. Copy from .env.example and configure credentials."; \
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
