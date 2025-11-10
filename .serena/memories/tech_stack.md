# Tech Stack

## Language and Runtime

- **Go Version**: 1.25
- **Module Structure**: Multi-module monorepo with replace directives

## Core Dependencies

### AccelByte Integration
- `github.com/AccelByte/accelbyte-go-sdk` v0.80.0 - AGS service integration
- `google.golang.org/grpc` v1.61.0 (event handler), v1.72.0 (backend)
- `google.golang.org/protobuf` v1.32.0 (event handler), v1.36.6 (backend)

### Database
- `github.com/lib/pq` v1.10.9 - PostgreSQL driver
- `github.com/golang-migrate/migrate/v4` v4.19.0 - Schema migrations
- PostgreSQL 15+ required

### Observability
- `github.com/sirupsen/logrus` - Structured logging
- `github.com/prometheus/client_golang` - Metrics
- `go.opentelemetry.io/otel` - Distributed tracing
- `go.opentelemetry.io/otel/exporters/zipkin` - Trace export

### Testing
- `github.com/stretchr/testify` - Test assertions and mocking
- `github.com/DATA-DOG/go-sqlmock` - Database mocking for unit tests
- Testcontainers - Integration testing with real PostgreSQL

## Demo App Dependencies (To Be Added)

- `github.com/charmbracelet/bubbletea` - TUI framework
- `github.com/charmbracelet/lipgloss` - TUI styling
- `github.com/charmbracelet/bubbles` - TUI components
- `github.com/spf13/viper` - Configuration management
- `github.com/spf13/cobra` - CLI framework
- `github.com/atotto/clipboard` - Clipboard operations

## Infrastructure

- **Container Runtime**: Docker + docker-compose for local development
- **Deployment**: AccelByte Extend platform (Kubernetes-based)
