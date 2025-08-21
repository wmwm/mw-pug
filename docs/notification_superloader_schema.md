# SuperLoader / NotificationAgent Integration Schema

This document defines the minimal contract between the NotificationAgent and SuperLoader for Harness #2.

## Overview

The SuperLoader will provide customization points for notification handling, while the NotificationAgent will expose standardized hooks for the SuperLoader to inject custom behavior.

## Schema Version 1.0

### SuperLoader Step Handler Types

The NotificationAgent expects the SuperLoader to implement these custom step handlers:

1. `preprocess_notification`: Process notifications before sending
   - Input: `{ userId, type, context }`
   - Output: `{ skip: boolean, context: Object, result: boolean }`

2. `check_expirations`: Custom expiration handling
   - Input: `{ stateStore: Map }`
   - Output: `{ handled: boolean }`

3. `queue_keep_alive_processing`: Queue-specific handling
   - Input: `{ userId, context }`
   - Output: `{ processed: boolean }`

### Event Handlers

The NotificationAgent will emit these events for SuperLoader to consume:

1. `config:refreshed`: Configuration was reloaded
2. `config:refresh_failed`: Configuration refresh failed
   - Data: `{ error }`

### SuperLoader Upgrade Schema

The SuperLoader YAML files for notification upgrades should follow this structure:

```yaml
version: '1.0'
description: 'Notification System Upgrade'
target: 'notification'

sequences:
  - id: 'notification_schema_update'
    description: 'Update notification schema'
    steps:
      - type: 'update_config'
        config: 'notification'
        values:
          schema_version: '1.0'
          # Additional configuration updates

  - id: 'notification_channels'
    description: 'Configure notification channels'
    requires:
      - 'notification_schema_update'
    steps:
      - type: 'create_channel'
        category: 'Notifications'
        name: 'critical-notifications'
        # Additional channel properties
        
  # Additional sequences
```

## Integration Points

The NotificationAgent will initialize SuperLoader with these integration points:

1. Constructor: Basic SuperLoader property setup
2. Initialize: Configure SuperLoader with dependencies and event handlers
3. Notification sending: Preprocessing hooks
4. Expiration handling: Custom expiration logic
5. Refresh configuration: Apply configuration changes after upgrades

## Testing

SuperLoader integration tests are located in `test/notification_superloader_test.js` and will be activated when Harness #2 is implemented.
