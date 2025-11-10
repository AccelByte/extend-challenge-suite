# Challenge Demo App - Configuration Technical Specification

## Document Purpose

This technical specification defines **configuration management**, including config file format, loading, validation, wizard, and persistence using Viper.

**Related Documents:**
- [TECH_SPEC_ARCHITECTURE.md](./TECH_SPEC_ARCHITECTURE.md) - ConfigManager interface
- [DESIGN.md](./DESIGN.md) - Config wizard user flow

---

## 1. Overview

### 1.1 Purpose

The Config component handles **loading, validating, and persisting** application configuration from multiple sources (file, env vars, CLI flags).

**Configuration Sources (priority order):**
1. **CLI flags** (highest priority)
2. **Environment variables**
3. **Config file** (`~/.challenge-demo/config.yaml`)
4. **Defaults** (lowest priority)

---

### 1.2 Interface (from TECH_SPEC_ARCHITECTURE.md)

```go
package config

// ConfigManager handles loading and saving configuration
type ConfigManager interface {
    // Load loads configuration from file, env vars, and CLI flags
    Load() (*Config, error)

    // Save saves configuration to file
    Save(config *Config) error

    // Exists checks if a config file exists
    Exists() bool
}
```

---

## 2. Config Struct

### 2.1 Complete Config Definition

```go
package config

import (
    "errors"
    "fmt"
)

// Config represents the application configuration
type Config struct {
    // Environment
    Environment string `yaml:"environment" mapstructure:"environment"` // local, staging, prod

    // API Configuration
    BackendURL string `yaml:"backend_url" mapstructure:"backend_url"` // Challenge Service URL
    IAMURL     string `yaml:"iam_url" mapstructure:"iam_url"`         // AGS IAM URL
    Namespace  string `yaml:"namespace" mapstructure:"namespace"`     // AGS namespace

    // Primary Authentication (for Challenge Service API)
    ClientID     string `yaml:"client_id" mapstructure:"client_id"`         // OAuth2 client ID
    ClientSecret string `yaml:"client_secret" mapstructure:"client_secret"` // OAuth2 client secret
    Email        string `yaml:"email" mapstructure:"email"`                 // User email (for password mode)
    Password     string `yaml:"password" mapstructure:"password"`           // User password (for password mode)
    UserID       string `yaml:"user_id" mapstructure:"user_id"`             // Test user ID (for mock mode)
    AuthMode     string `yaml:"auth_mode" mapstructure:"auth_mode"`         // "mock", "password", or "client"

    // Admin Authentication (optional - for AGS Platform verification)
    AdminClientID     string `yaml:"admin_client_id" mapstructure:"admin_client_id"`         // Admin OAuth2 client ID
    AdminClientSecret string `yaml:"admin_client_secret" mapstructure:"admin_client_secret"` // Admin OAuth2 client secret

    // Event Triggering
    EventHandlerURL  string `yaml:"event_handler_url" mapstructure:"event_handler_url"`   // For local mode
    EventTriggerMode string `yaml:"event_trigger_mode" mapstructure:"event_trigger_mode"` // "local" or "ags"
    KafkaBrokers     string `yaml:"kafka_brokers" mapstructure:"kafka_brokers"`           // For AGS mode

    // UI Preferences
    AutoRefresh     bool `yaml:"auto_refresh" mapstructure:"auto_refresh"`         // Enable watch mode by default
    RefreshInterval int  `yaml:"refresh_interval" mapstructure:"refresh_interval"` // Seconds (default: 2)
}
```

**Note:** `mapstructure` tags are for Viper, `yaml` tags are for manual marshaling.

---

### 2.2 Default Configuration

```go
// DefaultConfig returns a config with sensible defaults
func DefaultConfig() *Config {
    return &Config{
        Environment:      "local",
        BackendURL:       "http://localhost:8080",
        IAMURL:           "https://demo.accelbyte.io/iam",
        Namespace:        "accelbyte",
        UserID:           "test-user",
        AuthMode:         "ags",
        EventHandlerURL:  "localhost:6566",
        EventTriggerMode: "local",
        KafkaBrokers:     "",
        AutoRefresh:      false,
        RefreshInterval:  2,
    }
}
```

---

### 2.3 Config Validation

**Validate required fields and formats:**

```go
// Validate checks if the config is valid
func (c *Config) Validate() error {
    // Required fields
    if c.BackendURL == "" {
        return ErrMissingBackendURL
    }
    if c.Namespace == "" {
        return ErrMissingNamespace
    }

    // Auth mode validation
    validModes := []string{"mock", "password", "client"}
    validMode := false
    for _, mode := range validModes {
        if c.AuthMode == mode {
            validMode = true
            break
        }
    }
    if !validMode {
        return fmt.Errorf("auth_mode must be 'mock', 'password', or 'client', got: %s", c.AuthMode)
    }

    // Mode-specific validation
    switch c.AuthMode {
    case "password":
        if c.IAMURL == "" {
            return errors.New("iam_url required for password auth")
        }
        if c.ClientID == "" || c.ClientSecret == "" {
            return errors.New("client_id and client_secret required for password auth")
        }
        if c.Email == "" || c.Password == "" {
            return errors.New("email and password required for password auth")
        }

    case "client":
        if c.IAMURL == "" {
            return errors.New("iam_url required for client auth")
        }
        if c.ClientID == "" || c.ClientSecret == "" {
            return errors.New("client_id and client_secret required for client auth")
        }

    case "mock":
        if c.UserID == "" {
            return errors.New("user_id required for mock auth")
        }
    }

    // Admin auth validation (optional)
    // If one admin credential is set, both must be set
    if c.AdminClientID != "" || c.AdminClientSecret != "" {
        if c.AdminClientID == "" || c.AdminClientSecret == "" {
            return errors.New("both admin_client_id and admin_client_secret must be set if using admin auth")
        }
        if c.IAMURL == "" {
            return errors.New("iam_url required when using admin auth")
        }
    }

    // Event trigger mode validation
    if c.EventTriggerMode != "local" && c.EventTriggerMode != "ags" {
        return fmt.Errorf("event_trigger_mode must be 'local' or 'ags', got: %s", c.EventTriggerMode)
    }

    // Local mode requires event handler URL
    if c.EventTriggerMode == "local" && c.EventHandlerURL == "" {
        return errors.New("event_handler_url required for local event trigger mode")
    }

    // AGS mode requires Kafka brokers
    if c.EventTriggerMode == "ags" && c.KafkaBrokers == "" {
        return errors.New("kafka_brokers required for AGS event trigger mode")
    }

    // Refresh interval must be positive
    if c.RefreshInterval <= 0 {
        return errors.New("refresh_interval must be positive")
    }

    return nil
}
```

---

### 2.4 Environment Presets

**Quick config for common environments:**

```go
// EnvironmentPreset returns a preset config for a named environment
func EnvironmentPreset(name string) *Config {
    cfg := DefaultConfig()

    switch name {
    case "local":
        cfg.Environment = "local"
        cfg.BackendURL = "http://localhost:8080"
        cfg.EventHandlerURL = "localhost:6566"
        cfg.EventTriggerMode = "local"

    case "staging":
        cfg.Environment = "staging"
        cfg.BackendURL = "https://challenge-api.staging.accelbyte.io"
        cfg.IAMURL = "https://iam.staging.accelbyte.io"
        cfg.EventTriggerMode = "ags"
        cfg.KafkaBrokers = "kafka1.staging:9092,kafka2.staging:9092"

    case "prod":
        cfg.Environment = "prod"
        cfg.BackendURL = "https://challenge-api.accelbyte.io"
        cfg.IAMURL = "https://iam.accelbyte.io"
        cfg.EventTriggerMode = "ags"
        cfg.KafkaBrokers = "kafka1.prod:9092,kafka2.prod:9092"
    }

    return cfg
}
```

---

## 3. Viper Config Manager

### 3.1 ViperConfigManager Implementation

**Uses Viper for config loading:**

```go
package config

import (
    "fmt"
    "os"
    "path/filepath"

    "github.com/spf13/viper"
)

// ViperConfigManager implements ConfigManager using Viper
type ViperConfigManager struct {
    configPath string
    v          *viper.Viper
}

// NewViperConfigManager creates a new Viper config manager
func NewViperConfigManager() *ViperConfigManager {
    homeDir, _ := os.UserHomeDir()
    configPath := filepath.Join(homeDir, ".challenge-demo", "config.yaml")

    return &ViperConfigManager{
        configPath: configPath,
        v:          viper.New(),
    }
}

// WithConfigPath sets a custom config path (for testing)
func (m *ViperConfigManager) WithConfigPath(path string) *ViperConfigManager {
    m.configPath = path
    return m
}
```

---

### 3.2 Load Implementation

**Load from file, env vars, and CLI flags:**

```go
// Load loads configuration from all sources
func (m *ViperConfigManager) Load() (*Config, error) {
    // Set config file path
    m.v.SetConfigFile(m.configPath)
    m.v.SetConfigType("yaml")

    // Read config file (if exists)
    if err := m.v.ReadInConfig(); err != nil {
        if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
            return nil, fmt.Errorf("read config file: %w", err)
        }
        // Config file not found is OK, use defaults
    }

    // Bind environment variables
    m.v.SetEnvPrefix("CHALLENGE_DEMO")
    m.v.AutomaticEnv()

    // Set defaults
    m.setDefaults()

    // Unmarshal into struct
    var cfg Config
    if err := m.v.Unmarshal(&cfg); err != nil {
        return nil, fmt.Errorf("unmarshal config: %w", err)
    }

    // Validate
    if err := cfg.Validate(); err != nil {
        return nil, fmt.Errorf("invalid config: %w", err)
    }

    return &cfg, nil
}

// setDefaults sets default values in Viper
func (m *ViperConfigManager) setDefaults() {
    defaults := DefaultConfig()

    m.v.SetDefault("environment", defaults.Environment)
    m.v.SetDefault("backend_url", defaults.BackendURL)
    m.v.SetDefault("iam_url", defaults.IAMURL)
    m.v.SetDefault("namespace", defaults.Namespace)
    m.v.SetDefault("user_id", defaults.UserID)
    m.v.SetDefault("auth_mode", defaults.AuthMode)
    m.v.SetDefault("event_handler_url", defaults.EventHandlerURL)
    m.v.SetDefault("event_trigger_mode", defaults.EventTriggerMode)
    m.v.SetDefault("auto_refresh", defaults.AutoRefresh)
    m.v.SetDefault("refresh_interval", defaults.RefreshInterval)
}
```

---

### 3.3 Save Implementation

**Save config to file:**

```go
// Save saves configuration to file
func (m *ViperConfigManager) Save(cfg *Config) error {
    // Validate before saving
    if err := cfg.Validate(); err != nil {
        return fmt.Errorf("invalid config: %w", err)
    }

    // Create config directory if not exists
    configDir := filepath.Dir(m.configPath)
    if err := os.MkdirAll(configDir, 0755); err != nil {
        return fmt.Errorf("create config directory: %w", err)
    }

    // Marshal config to YAML
    data := map[string]interface{}{
        "environment":        cfg.Environment,
        "backend_url":        cfg.BackendURL,
        "iam_url":            cfg.IAMURL,
        "namespace":          cfg.Namespace,
        "client_id":          cfg.ClientID,
        "client_secret":      cfg.ClientSecret,
        "user_id":            cfg.UserID,
        "auth_mode":          cfg.AuthMode,
        "event_handler_url":  cfg.EventHandlerURL,
        "event_trigger_mode": cfg.EventTriggerMode,
        "kafka_brokers":      cfg.KafkaBrokers,
        "auto_refresh":       cfg.AutoRefresh,
        "refresh_interval":   cfg.RefreshInterval,
    }

    // Update Viper with new values
    for key, value := range data {
        m.v.Set(key, value)
    }

    // Write to file
    if err := m.v.WriteConfigAs(m.configPath); err != nil {
        return fmt.Errorf("write config file: %w", err)
    }

    // Set restrictive permissions (owner read/write only)
    if err := os.Chmod(m.configPath, 0600); err != nil {
        return fmt.Errorf("set config file permissions: %w", err)
    }

    return nil
}
```

---

### 3.4 Exists Implementation

**Check if config file exists:**

```go
// Exists checks if a config file exists
func (m *ViperConfigManager) Exists() bool {
    _, err := os.Stat(m.configPath)
    return err == nil
}
```

---

## 4. Config Wizard

### 4.1 Wizard Flow

**Interactive setup on first launch:**

```go
package config

import (
    "bufio"
    "fmt"
    "os"
    "strings"
)

// Wizard runs an interactive config setup
type Wizard struct {
    reader *bufio.Reader
}

// NewWizard creates a new config wizard
func NewWizard() *Wizard {
    return &Wizard{
        reader: bufio.NewReader(os.Stdin),
    }
}

// Run runs the wizard and returns a configured Config
func (w *Wizard) Run() (*Config, error) {
    fmt.Println("Challenge Demo - First Time Setup")
    fmt.Println("==================================")
    fmt.Println()

    cfg := DefaultConfig()

    // Step 1: Environment
    if err := w.askEnvironment(cfg); err != nil {
        return nil, err
    }

    // Step 2: Backend URL (use preset if environment selected)
    if err := w.askBackendURL(cfg); err != nil {
        return nil, err
    }

    // Step 3: Namespace
    if err := w.askNamespace(cfg); err != nil {
        return nil, err
    }

    // Step 4: User ID
    if err := w.askUserID(cfg); err != nil {
        return nil, err
    }

    // Step 5: Auth mode
    if err := w.askAuthMode(cfg); err != nil {
        return nil, err
    }

    // Step 6: Credentials (if AGS auth)
    if cfg.AuthMode == "ags" {
        if err := w.askCredentials(cfg); err != nil {
            return nil, err
        }
    }

    // Step 7: Event trigger mode
    if err := w.askEventTriggerMode(cfg); err != nil {
        return nil, err
    }

    // Step 8: Event handler URL (if local mode)
    if cfg.EventTriggerMode == "local" {
        if err := w.askEventHandlerURL(cfg); err != nil {
            return nil, err
        }
    }

    fmt.Println()
    fmt.Println("Configuration complete!")
    fmt.Println()

    return cfg, nil
}
```

---

### 4.2 Wizard Steps

**Individual question methods:**

```go
// askEnvironment asks for environment preset
func (w *Wizard) askEnvironment(cfg *Config) error {
    fmt.Println("Select environment:")
    fmt.Println("  1) Local Development")
    fmt.Println("  2) AGS Staging")
    fmt.Println("  3) AGS Production")
    fmt.Println("  4) Custom")
    fmt.Print("Choice [1]: ")

    choice := w.readLine()
    if choice == "" {
        choice = "1"
    }

    switch choice {
    case "1":
        *cfg = *EnvironmentPreset("local")
    case "2":
        *cfg = *EnvironmentPreset("staging")
    case "3":
        *cfg = *EnvironmentPreset("prod")
    case "4":
        // Keep defaults, user will customize
    default:
        fmt.Println("Invalid choice, using Local Development")
        *cfg = *EnvironmentPreset("local")
    }

    return nil
}

// askBackendURL asks for backend API URL
func (w *Wizard) askBackendURL(cfg *Config) error {
    fmt.Printf("Backend API URL [%s]: ", cfg.BackendURL)
    input := w.readLine()
    if input != "" {
        cfg.BackendURL = input
    }
    return nil
}

// askNamespace asks for AGS namespace
func (w *Wizard) askNamespace(cfg *Config) error {
    fmt.Printf("AGS Namespace [%s]: ", cfg.Namespace)
    input := w.readLine()
    if input != "" {
        cfg.Namespace = input
    }
    return nil
}

// askUserID asks for test user ID
func (w *Wizard) askUserID(cfg *Config) error {
    fmt.Printf("Test User ID [%s]: ", cfg.UserID)
    input := w.readLine()
    if input != "" {
        cfg.UserID = input
    }
    return nil
}

// askAuthMode asks for auth mode
func (w *Wizard) askAuthMode(cfg *Config) error {
    fmt.Println("Authentication mode:")
    fmt.Println("  1) AGS (real OAuth2)")
    fmt.Println("  2) Mock (for local dev)")
    fmt.Print("Choice [1]: ")

    choice := w.readLine()
    if choice == "" || choice == "1" {
        cfg.AuthMode = "ags"
    } else if choice == "2" {
        cfg.AuthMode = "mock"
    }

    return nil
}

// askCredentials asks for OAuth2 credentials
func (w *Wizard) askCredentials(cfg *Config) error {
    fmt.Print("Client ID: ")
    cfg.ClientID = w.readLine()

    fmt.Print("Client Secret: ")
    cfg.ClientSecret = w.readLineSecret()

    return nil
}

// askEventTriggerMode asks for event trigger mode
func (w *Wizard) askEventTriggerMode(cfg *Config) error {
    fmt.Println("Event trigger mode:")
    fmt.Println("  1) Local (gRPC to event handler)")
    fmt.Println("  2) AGS (Kafka Event Bus)")
    fmt.Print("Choice [1]: ")

    choice := w.readLine()
    if choice == "" || choice == "1" {
        cfg.EventTriggerMode = "local"
    } else if choice == "2" {
        cfg.EventTriggerMode = "ags"
    }

    return nil
}

// askEventHandlerURL asks for event handler URL
func (w *Wizard) askEventHandlerURL(cfg *Config) error {
    fmt.Printf("Event Handler URL [%s]: ", cfg.EventHandlerURL)
    input := w.readLine()
    if input != "" {
        cfg.EventHandlerURL = input
    }
    return nil
}

// readLine reads a line from stdin
func (w *Wizard) readLine() string {
    line, _ := w.reader.ReadString('\n')
    return strings.TrimSpace(line)
}

// readLineSecret reads a line without echoing (for passwords)
func (w *Wizard) readLineSecret() string {
    // For MVP, just use regular input
    // Future: use terminal.ReadPassword()
    return w.readLine()
}
```

---

## 5. CLI Flags

### 5.1 Flag Definition

**Use cobra for CLI flags:**

```go
package main

import (
    "github.com/spf13/cobra"
    "github.com/AccelByte/extend-challenge/extend-challenge-demo-app/internal/config"
)

var (
    flagConfigPath  string
    flagEnvironment string
    flagBackendURL  string
    flagNamespace   string
    flagUserID      string
    flagSetup       bool
)

func init() {
    rootCmd.PersistentFlags().StringVar(&flagConfigPath, "config", "", "Config file path")
    rootCmd.PersistentFlags().StringVar(&flagEnvironment, "env", "", "Environment (local/staging/prod)")
    rootCmd.PersistentFlags().StringVar(&flagBackendURL, "backend-url", "", "Backend API URL")
    rootCmd.PersistentFlags().StringVar(&flagNamespace, "namespace", "", "AGS namespace")
    rootCmd.PersistentFlags().StringVar(&flagUserID, "user", "", "Test user ID")
    rootCmd.PersistentFlags().BoolVar(&flagSetup, "setup", false, "Run config wizard")
}
```

---

### 5.2 Flag Override

**Apply CLI flags after loading config:**

```go
func loadConfig() (*config.Config, error) {
    // Create config manager
    mgr := config.NewViperConfigManager()
    if flagConfigPath != "" {
        mgr = mgr.WithConfigPath(flagConfigPath)
    }

    // Check if setup flag is set
    if flagSetup {
        wizard := config.NewWizard()
        cfg, err := wizard.Run()
        if err != nil {
            return nil, err
        }

        // Save config
        if err := mgr.Save(cfg); err != nil {
            return nil, err
        }

        return cfg, nil
    }

    // Check if config exists
    if !mgr.Exists() {
        fmt.Println("Config file not found. Run setup? (y/n):")
        var response string
        fmt.Scanln(&response)

        if response == "y" || response == "Y" {
            wizard := config.NewWizard()
            cfg, err := wizard.Run()
            if err != nil {
                return nil, err
            }

            if err := mgr.Save(cfg); err != nil {
                return nil, err
            }

            return cfg, nil
        }

        return nil, errors.New("config required, run with --setup flag")
    }

    // Load config
    cfg, err := mgr.Load()
    if err != nil {
        return nil, err
    }

    // Apply CLI flag overrides
    if flagEnvironment != "" {
        cfg.Environment = flagEnvironment
    }
    if flagBackendURL != "" {
        cfg.BackendURL = flagBackendURL
    }
    if flagNamespace != "" {
        cfg.Namespace = flagNamespace
    }
    if flagUserID != "" {
        cfg.UserID = flagUserID
    }

    return cfg, nil
}
```

---

## 6. Environment Variables

### 6.1 Env Var Naming

**Convention:** `CHALLENGE_DEMO_<CONFIG_KEY>`

**Examples:**
```bash
# Environment and API
CHALLENGE_DEMO_ENVIRONMENT=prod
CHALLENGE_DEMO_BACKEND_URL=https://challenge-api.accelbyte.io
CHALLENGE_DEMO_NAMESPACE=my-namespace
CHALLENGE_DEMO_IAM_URL=https://iam.accelbyte.io

# Primary Authentication
CHALLENGE_DEMO_CLIENT_ID=my-client-id
CHALLENGE_DEMO_CLIENT_SECRET=my-secret
CHALLENGE_DEMO_EMAIL=user@example.com
CHALLENGE_DEMO_PASSWORD=my-password
CHALLENGE_DEMO_USER_ID=test-user
CHALLENGE_DEMO_AUTH_MODE=password

# Admin Authentication (optional)
CHALLENGE_DEMO_ADMIN_CLIENT_ID=admin-client-id
CHALLENGE_DEMO_ADMIN_CLIENT_SECRET=admin-secret

# Event Triggering
CHALLENGE_DEMO_EVENT_TRIGGER_MODE=local
CHALLENGE_DEMO_EVENT_HANDLER_URL=localhost:6566
```

**Viper automatically binds these with `SetEnvPrefix` and `AutomaticEnv()`.**

---

## 7. Config File Format

### 7.1 Example Config File

**`~/.challenge-demo/config.yaml`:**

```yaml
# Environment: local, staging, prod
environment: local

# API Configuration
backend_url: http://localhost:8080
iam_url: https://demo.accelbyte.io/iam
namespace: accelbyte

# Primary Authentication (for Challenge Service API)
client_id: my-client-id
client_secret: my-client-secret
email: user@example.com  # For password mode
password: my-password    # For password mode
user_id: test-user       # For mock mode
auth_mode: password      # "mock", "password", or "client"

# Admin Authentication (optional - for AGS Platform verification)
admin_client_id: admin-client-id
admin_client_secret: admin-client-secret

# Event Triggering
event_handler_url: localhost:6566
event_trigger_mode: local  # "local" or "ags"
kafka_brokers: ""

# UI Preferences
auto_refresh: false
refresh_interval: 2
```

### 7.2 Comments in Config

**Viper preserves comments when reading, but not when writing (limitation).**

**Workaround:** Include commented template in README:

```markdown
## Config File Template

```yaml
# Copy this to ~/.challenge-demo/config.yaml and customize

environment: local
backend_url: http://localhost:8080
iam_url: https://demo.accelbyte.io/iam
namespace: accelbyte

client_id: your-client-id-here
client_secret: your-client-secret-here
user_id: test-user
auth_mode: ags

event_handler_url: localhost:6566
event_trigger_mode: local

auto_refresh: false
refresh_interval: 2
```
```

---

## 8. Testing

### 8.1 Unit Tests

**Test config loading:**

```go
func TestViperConfigManager_Load(t *testing.T) {
    // Create temp config file
    tempDir := t.TempDir()
    configPath := filepath.Join(tempDir, "config.yaml")

    configContent := `
environment: staging
backend_url: https://test.example.com
namespace: test-namespace
user_id: test-user
auth_mode: mock
event_trigger_mode: local
event_handler_url: localhost:6566
refresh_interval: 5
`
    os.WriteFile(configPath, []byte(configContent), 0600)

    // Load config
    mgr := config.NewViperConfigManager().WithConfigPath(configPath)
    cfg, err := mgr.Load()

    assert.NoError(t, err)
    assert.Equal(t, "staging", cfg.Environment)
    assert.Equal(t, "https://test.example.com", cfg.BackendURL)
    assert.Equal(t, "test-namespace", cfg.Namespace)
    assert.Equal(t, "mock", cfg.AuthMode)
    assert.Equal(t, 5, cfg.RefreshInterval)
}
```

---

### 8.2 Test Config Validation

```go
func TestConfig_Validate(t *testing.T) {
    tests := []struct {
        name    string
        config  *config.Config
        wantErr bool
    }{
        {
            name:    "valid config",
            config:  config.DefaultConfig(),
            wantErr: false,
        },
        {
            name: "missing backend URL",
            config: &config.Config{
                Namespace: "demo",
                UserID:    "test",
            },
            wantErr: true,
        },
        {
            name: "invalid auth mode",
            config: &config.Config{
                BackendURL: "http://localhost:8080",
                Namespace:  "demo",
                UserID:     "test",
                AuthMode:   "invalid",
            },
            wantErr: true,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := tt.config.Validate()
            if tt.wantErr {
                assert.Error(t, err)
            } else {
                assert.NoError(t, err)
            }
        })
    }
}
```

---

## 9. Summary

**Key Implementation Details:**

1. **Config Sources:** CLI flags > Env vars > Config file > Defaults
2. **Viper Integration:** Automatic env binding, file loading, marshaling
3. **Config Wizard:** Interactive setup on first launch
4. **Validation:** Comprehensive validation with clear error messages
5. **Security:** File permissions (0600), warn if too open

**Configuration Flow:**
1. Check if config exists
2. If not, prompt to run wizard
3. Load config from file
4. Apply env var overrides
5. Apply CLI flag overrides
6. Validate final config

**File Location:**
- Default: `~/.challenge-demo/config.yaml`
- Override: `--config /path/to/config.yaml`

**Next Steps:**
1. Review and approve this spec
2. Implement ViperConfigManager (Phase 5)
3. Implement config wizard (Phase 5)
4. Test with various config sources

---

**Document Version:** 1.0
**Last Updated:** 2025-10-20
**Status:** ✅ Ready for Review
