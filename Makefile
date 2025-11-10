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
	@echo "  make test-e2e        - Run all E2E tests"
	@echo "  make test-e2e-login  - Test login flow"
	@echo "  make test-e2e-stat   - Test stat update flow"
	@echo "  make test-e2e-daily  - Test daily goal behavior"
	@echo "  make test-e2e-buffering - Test performance & buffering"
	@echo "  make test-e2e-prereqs - Test prerequisites"
	@echo "  make test-e2e-mixed  - Test mixed goal types"
	@echo "  make test-e2e-errors - Test error scenarios"
	@echo "  make test-e2e-rewards - Test reward failures"
	@echo "  make test-e2e-multiuser - Test multi-user isolation"

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
.PHONY: test-e2e
test-e2e:
	@echo "Running all E2E tests..."
	cd tests/e2e && ./run-all-tests.sh

.PHONY: test-e2e-login
test-e2e-login:
	cd tests/e2e && ./test-login-flow.sh

.PHONY: test-e2e-stat
test-e2e-stat:
	cd tests/e2e && ./test-stat-flow.sh

.PHONY: test-e2e-daily
test-e2e-daily:
	cd tests/e2e && ./test-daily-goal.sh

.PHONY: test-e2e-buffering
test-e2e-buffering:
	cd tests/e2e && ./test-buffering-performance.sh

.PHONY: test-e2e-prereqs
test-e2e-prereqs:
	cd tests/e2e && ./test-prerequisites.sh

.PHONY: test-e2e-mixed
test-e2e-mixed:
	cd tests/e2e && ./test-mixed-goals.sh

.PHONY: test-e2e-errors
test-e2e-errors:
	cd tests/e2e && ./test-error-scenarios.sh

.PHONY: test-e2e-rewards
test-e2e-rewards:
	cd tests/e2e && ./test-reward-failures.sh

.PHONY: test-e2e-multiuser
test-e2e-multiuser:
	cd tests/e2e && ./test-multi-user.sh
