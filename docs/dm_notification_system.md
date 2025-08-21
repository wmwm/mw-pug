# DM Notification System

## Overview

The DM Notification system provides a robust framework for delivering private, interactive prompts to users that require responses to maintain participation in various bot activities.

Key features:

- Keep-alive checks for match queues
- Ready checks before server allocation
- Role retention activity checks
- Fallback to public channels if DMs are disabled
- Comprehensive audit logging

## Design Principles

1. **Signal over noise** – Only send DMs when interaction is essential to progress, account security, or continuity.
2. **State tracking** – Every outbound DM sets a "response required" flag that's cleared when the player replies or times out.
3. **Fail-safe fallback** – If DMs are disabled, surface the query in a visible public channel with minimal sensitive info.

## Configuration

The DM Notification system is configured in `config/dm_notification.yml`:

```yaml
dm_notification:
  # Enable/disable the plugin
  enabled: true
  
  # Notification triggers
  triggers:
    match_queue: true      # Keep-alive for queue
    pre_game: true         # Ready check before game starts
    role_retention: false  # Activity check for role retention
  
  # Timeouts (in seconds)
  timeout_seconds:
    match_queue: 120       # 2 minutes for queue keep-alive
    pre_game: 60           # 1 minute for pre-game ready check
    role_retention: 604800 # 1 week for role retention
  
  # DM templates - use {placeholders} for dynamic content
  dm_templates:
    match_queue: "🔔 You're queued for {match_name}. Reply `!ready` within {timeout} seconds to stay in queue."
    pre_game: "🎮 Your match {match_id} is about to start! Reply `!ready` within {timeout} seconds or you'll be removed."
    role_retention: "👋 To maintain your {role_name} role, please reply `!active` within {timeout} seconds."
  
  # Fallback channel if DMs are disabled
  fallback_channel_id: "1234567890"
  
  # Audit logging
  log_channel_id: "0987654321"
  audit_log: true
  
  # Auto-remove users who don't respond
  auto_remove: true
  
  # Max pending notifications per user (to avoid spam)
  max_pending_per_user: 3
```

## Commands

### Player Commands

- `!ready` - Confirm readiness for match queue or pre-game check
- `!active` - Confirm activity for role retention

### Admin Commands

- `!togglekeepalive [on|off]` - Enable or disable keep-alive checks
- `!keepalive` - Show overall status of the keep-alive system
- `!keepalive list` - List active keep-alive checks
- `!keepalive clear @user` - Clear all keep-alive checks for a user
- `!keepalive triggers` - Show status of all triggers
- `!keepalive settrigger <trigger> <on|off>` - Enable/disable a specific trigger

## State Machine

The notification system operates as a state machine:

```mermaid
[*] --> Waiting
Waiting --> PromptSent : TriggerEvent
PromptSent --> Confirmed : ReplyValid
PromptSent --> TimedOut : NoReply
Confirmed --> [*]
TimedOut --> Removed : ApplyConsequence
Removed --> [*]
```

## Integration with Other Plugins

To use the DM Notification system in other plugins, first get a reference to the plugin:

```ruby
dm_notification = @plugin_manager.get_plugin("DMNotification")
```

Then you can use the following methods:

```ruby
# Send a queue keep-alive check
dm_notification.queue_keep_alive(user, match_name, queue_id)

# Send a pre-game ready check
dm_notification.pre_game_ready_check(user, match_id, match_details)

# Send a role retention activity check
dm_notification.role_retention_check(user, role_name)

# Check if a user has pending notifications
dm_notification.has_pending_notifications?(user_id)

# Get count of pending notifications
dm_notification.pending_notification_count(user_id)

# Clear notifications for a user
dm_notification.clear_notifications(user_id, type = nil)
```

## Audit Logging

The notification system logs all events to the configured log channel, including:

- Notification sent
- Response received (with latency)
- Timeout expiration
- Fallback to public channel
- Removal actions
- Admin actions

## Acceptance Tests

The following acceptance tests are provided to validate the system:

1. **Reply within timeout** - User stays in queue/match
2. **No reply** - User is auto-removed, notified
3. **DMs disabled** - Fallback public ping is sent
4. **Multiple prompts** - Each prompt is tracked separately

Run tests with:

```bash
ruby test/dm_notification_plugin_test.rb
```

## Best Practices

1. **Keep DMs minimal** - Only send essential notifications
2. **Self-contained messages** - Include all needed context in the DM
3. **Clear instructions** - Tell users exactly what response is needed
4. **Respect privacy** - Don't include sensitive data in fallback messages
5. **Consistent language** - Use consistent terminology and formatting
