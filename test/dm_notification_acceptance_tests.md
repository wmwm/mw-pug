# DM Notification System Acceptance Tests

This document outlines the acceptance tests for the DM Notification system to ensure it meets the design requirements and functions correctly.

## Test Environment Setup

1. Configure a test Discord server with:
   - Bot with proper permissions
   - Test channels for notifications and logs
   - Test roles for permission testing
   - At least 3 test users (Admin, Regular User, User with DMs disabled)

2. Configure the bot with:
   ```yaml
   dm_notification:
     enabled: true
     triggers:
       match_queue: true
       pre_game: true
       role_retention: true
     timeout_seconds:
       match_queue: 30       # shorter for testing
       pre_game: 30
       role_retention: 60
     fallback_channel_id: "ID_OF_TEST_FALLBACK_CHANNEL"
     log_channel_id: "ID_OF_TEST_LOG_CHANNEL"
   ```

## Core Acceptance Tests

| ID  | Test Case                        | Steps                                                                               | Expected Result                                          | Pass/Fail |
|-----|----------------------------------|-------------------------------------------------------------------------------------|---------------------------------------------------------|-----------|
| 1.1 | Player replies in time           | 1. Add player to queue<br>2. Trigger keep-alive<br>3. Player responds with `!ready` | Player stays in queue, gets confirmation message         |           |
| 1.2 | Player ignores message           | 1. Add player to queue<br>2. Trigger keep-alive<br>3. Wait for timeout              | Player removed from queue, receives removal notification |           |
| 1.3 | Player has DMs off               | 1. Add player (with DMs off) to queue<br>2. Trigger keep-alive                      | Fallback message sent to public channel                  |           |
| 1.4 | Multiple prompts don't conflict  | 1. Trigger queue keep-alive<br>2. Trigger pre-game check for same user              | Both prompts tracked separately, both require response   |           |

## Queue Keep-Alive Tests

| ID  | Test Case                          | Steps                                                                                                 | Expected Result                                                  | Pass/Fail |
|-----|------------------------------------|----------------------------------------------------------------------------------------------------|----------------------------------------------------------------|-----------|
| 2.1 | Queue idle timeout triggers DM     | 1. Join queue<br>2. Wait for idle timeout trigger                                                    | User receives DM with proper instructions                        |           |
| 2.2 | Reply keeps player in queue        | 1. Join queue<br>2. Receive idle timeout DM<br>3. Reply with `!ready`                                | Queue status shows player still active                           |           |
| 2.3 | No reply removes player            | 1. Join queue<br>2. Receive idle timeout DM<br>3. Don't reply until timeout                          | Player removed from queue, receives notification                 |           |
| 2.4 | Wrong reply format                 | 1. Join queue<br>2. Receive idle timeout DM<br>3. Reply with incorrect format (e.g. "yes")           | No action until timeout, then removed                            |           |
| 2.5 | Multiple queues at once            | 1. Join multiple queues<br>2. Trigger keep-alive for all queues                                      | Each queue tracked separately, can respond to each individually  |           |

## Pre-Game Ready Check Tests

| ID  | Test Case                           | Steps                                                                              | Expected Result                                                 | Pass/Fail |
|-----|------------------------------------|-------------------------------------------------------------------------------------|----------------------------------------------------------------|-----------|
| 3.1 | Pre-game check triggers DM         | 1. Match is forming<br>2. Server allocation about to start                         | All players receive pre-game ready check DM                     |           |
| 3.2 | Ready response marks player ready  | 1. Receive pre-game check<br>2. Reply with `!ready`                                | Player marked as ready in match system                           |           |
| 3.3 | No response marks player not ready | 1. Receive pre-game check<br>2. Don't reply                                        | Player marked as not ready after timeout                         |           |
| 3.4 | Public response works              | 1. Receive pre-game check<br>2. Reply with `!ready` in public channel              | Player marked as ready (if fallback configured properly)         |           |

## Role Retention Tests

| ID  | Test Case                         | Steps                                                                             | Expected Result                                             | Pass/Fail |
|-----|----------------------------------|-------------------------------------------------------------------------------------|-------------------------------------------------------------|-----------|
| 4.1 | Activity check sends DM          | 1. Trigger role retention check for user with specific role                        | User receives DM asking to confirm activity                  |           |
| 4.2 | Active response retains role     | 1. Receive activity check DM<br>2. Reply with `!active`                            | User keeps role, receives confirmation                       |           |
| 4.3 | No response removes role         | 1. Receive activity check DM<br>2. Don't reply until timeout                       | User loses role after timeout                                |           |

## Admin Command Tests

| ID  | Test Case                           | Steps                                                                    | Expected Result                                                | Pass/Fail |
|-----|------------------------------------|---------------------------------------------------------------------------|-----------------------------------------------------------------|-----------|
| 5.1 | Toggle keep-alive off              | 1. Run `!togglekeepalive off`<br>2. Trigger a keep-alive                  | No DMs are sent, system reports as disabled                     |           |
| 5.2 | Toggle keep-alive on               | 1. Run `!togglekeepalive on`<br>2. Trigger a keep-alive                   | DMs are sent as normal, system reports as enabled               |           |
| 5.3 | Clear user checks                  | 1. User has pending checks<br>2. Run `!keepalive clear @user`             | All pending checks for user are removed                         |           |
| 5.4 | List active checks                 | 1. Multiple users have pending checks<br>2. Run `!keepalive list`         | Shows list of users with pending notifications and expiry times |           |
| 5.5 | Disable specific trigger           | 1. Run `!keepalive settrigger match_queue off`<br>2. Trigger a keep-alive | Queue keep-alive DMs aren't sent, other types still work        |           |

## Edge Cases

| ID  | Test Case                            | Steps                                                                              | Expected Result                                               | Pass/Fail |
|-----|------------------------------------|------------------------------------------------------------------------------------|---------------------------------------------------------------|-----------|
| 6.1 | User leaves server during check    | 1. Send notification<br>2. User leaves server before timeout                       | State cleaned up, no errors                                    |           |
| 6.2 | Bot restarts during active checks  | 1. Send notifications<br>2. Restart bot                                            | State persists if using persistent storage                     |           |
| 6.3 | Max pending notifications          | 1. Trigger many notifications for same user                                        | Only sends up to max_pending_per_user notifications            |           |
| 6.4 | Rate limiting                      | 1. Trigger notifications for many users at once                                    | Handles rate limits gracefully                                 |           |

## Audit Log Tests

| ID  | Test Case                      | Steps                                                           | Expected Result                                        | Pass/Fail |
|-----|-------------------------------|------------------------------------------------------------------|--------------------------------------------------------|-----------|
| 7.1 | DM sent logging               | 1. Trigger notification<br>2. Check audit log                    | Log entry shows user, type, timestamp                  |           |
| 7.2 | Response logging              | 1. Send notification<br>2. User responds<br>3. Check audit log   | Log entry shows response time, message content         |           |
| 7.3 | Timeout logging               | 1. Send notification<br>2. Let timeout expire<br>3. Check log    | Log entry shows timeout event and action taken         |           |
| 7.4 | Admin action logging          | 1. Admin toggles system<br>2. Check audit log                    | Log shows admin action, user who performed it          |           |

## Test Completion Checklist

- [ ] All core tests passing
- [ ] All queue keep-alive tests passing
- [ ] All pre-game tests passing
- [ ] All role retention tests passing
- [ ] All admin command tests passing
- [ ] All edge cases handled
- [ ] All audit logging tests passing

## Notes for Test Execution

1. Use automated unit tests where possible
2. Manual testing required for full Discord integration
3. Record any discrepancies between expected and actual behavior
4. Document any additional edge cases discovered during testing
5. Update documentation based on test findings
