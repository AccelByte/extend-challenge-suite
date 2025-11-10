# Project Overview

## Purpose

This repository implements a **Challenge Service** as an AccelByte Extend application. The system enables game developers to implement challenge systems (daily missions, seasonal events, quests, achievements) with minimal configuration through a JSON config file.

## Key Features

- **Config-First Approach**: Challenges defined in JSON, no admin CRUD API needed
- **Event-Driven Progress**: Stats updated via AGS events (IAM login, Statistic updates)
- **High-Performance Buffering**: 1,000,000x DB load reduction through batch UPSERT
- **Reward Distribution**: Integration with AGS Platform Service for item grants
- **Lazy Initialization**: User progress rows created on-demand

## Architecture Components

1. **Backend Service** (`extend-challenge-service`) - REST API for queries and claiming
2. **Event Handler** (`extend-challenge-event-handler`) - gRPC service for event processing
3. **Common Library** (`extend-challenge-common`) - Shared domain models and interfaces
4. **Demo App** (`extend-challenge-demo-app`) - TUI application for testing and demonstration

## Current Status

- M1 implementation complete (Phases 1-7.7)
- Backend service and event handler operational
- Demo app planning complete, implementation starting (Phase 0)
