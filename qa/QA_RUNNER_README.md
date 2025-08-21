# Discord QA Edge-Case Runner — v1.3.0 Notification System

## Overview

This QA Edge-Case Runner automates the testing of the v1.3.0 notification system, specifically focusing on the integration between NotificationAgent and SuperLoader. It validates:

- NotificationAgent ↔ SuperLoader integration
- YAML-driven behavior
- Fail-safe + fallback logic

## Test Scenarios

The QA runner implements 17 test scenarios covering various edge cases:

### Expiration Tests

- **EXP_BOUNDARY** — Trigger exactly at configured expiry timestamp.
- **EXP_FUTURE_JUMP** — Schedule days ahead, simulate time skip.
- **EXP_MIXED_TYPES** — Batch with multiple notification types.

### Keep-Alive Tests

- **KA_DORMANT** — Inactive > threshold.
- **KA_ACTIVE_IDLE** — Online but no interactions.
- **KA_CONCURRENT** — Multiple keep-alive triggers in <10s.

### Preprocessing Tests

- **PRE_UNKNOWN_TYPE** — Inject unknown notification type.
- **PRE_MISSING_FIELDS** — Drop optional fields; verify defaults.
- **PRE_SCHEMA_DRIFT** — Alter key names in YAML.

### Queue Tests

- **Q_HIGH_BURST** — Flood > batch limit.
- **Q_OUT_OF_ORDER** — Deliver older queued msg after newer.
- **Q_FALLBACK** — Preferred channel fails.

### Configuration Tests

- **CFG_HOT_SWAP** — Live YAML config change.
- **CFG_CONFLICT** — Simultaneous conflicting updates.

### Failure Tests

- **FAIL_NO_SUPERLOADER** — Simulate downtime.
- **FAIL_PARTIAL_RESTORE** — Crash mid-processing.
- **FAIL_INVALID_YAML** — Load corrupt config.

## Usage

### In Discord

The QA Runner registers a `!qa` command in Discord with the following options:

- `!qa scenario=<scenario_id>` - Run a specific scenario
- `!qa run=all` - Run all scenarios sequentially

Results are displayed inline with ✅/❌ indicators, and detailed diagnostic information is logged to the configured `#qa-logs` channel.

### Command Line

You can also run the tests from the command line using the provided CLI tool:

```bash
# Run all test scenarios
node qa/qa_notification_runner_cli.js

# Run a specific scenario
node qa/qa_notification_runner_cli.js EXP_BOUNDARY
```

## Configuration

Test configuration is stored in `config/qa_notification_test.yaml`. This file contains:

- Test user IDs for different user states (standard, DND, offline)
- Channel IDs for logging
- Detailed configuration for each test scenario
- Notification templates used in testing

## Implementation Details

The QA Runner is implemented in two main files:

- `qa/qa_notification_runner.js` - Main implementation of the QA test scenarios
- `qa/qa_notification_runner_cli.js` - CLI wrapper for running tests outside Discord

The runner uses mock dependencies when run via CLI to allow for offline testing.

## Pass Criteria

A successful test run will meet these criteria:

- All scenarios return ✅
- No unexpected errors in `#qa-logs`
- Behavior matches schema + design intent as defined in `notification_superloader_schema.md`

## Troubleshooting

If a test fails, the error message will be displayed inline and detailed diagnostic information will be logged to the `#qa-logs` channel. Common issues include:

- Missing configuration (check `qa_notification_test.yaml`)
- SuperLoader integration points not implemented correctly
- Timing issues (increase `waitBetweenScenarios` or `scenarioTimeout` if needed)

## Next Steps for Sprint Planning

1. Expand test coverage for cross-agent notification interactions
2. Implement performance benchmarking for notification delivery
3. Add visual testing for notification appearance in Discord
4. Create automated regression test suite that runs on CI/CD
