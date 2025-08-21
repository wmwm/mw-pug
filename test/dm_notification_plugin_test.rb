require 'minitest/autorun'
require 'discordrb'
require_relative '../bot/plugins/dm_notification_plugin'

class DMNotificationPluginTest < Minitest::Test
  def setup
    # Mock the bot object
    @bot = Minitest::Mock.new
    
    # Setup configuration for testing
    @config = {
      enabled: true,
      triggers: {
        match_queue: true,
        pre_game: true,
        role_retention: false
      },
      timeout_seconds: {
        match_queue: 5, # Use shorter timeout for tests
        pre_game: 3,
        role_retention: 10
      },
      dm_templates: {
        match_queue: "Test queue notification: {match_name}, {timeout} seconds",
        pre_game: "Test pre-game notification: {match_id}, {timeout} seconds",
        role_retention: "Test role notification: {role_name}, {timeout} seconds"
      },
      fallback_channel_id: "123456789",
      log_channel_id: nil,
      audit_log: false
    }
    
    # Create the plugin instance
    @plugin = DMNotificationPlugin.new(@bot, @config)
    
    # Mock user and DM channel
    @user = Minitest::Mock.new
    @dm_channel = Minitest::Mock.new
  end
  
  def test_queue_keep_alive_sends_notification
    # Setup mocks
    user_id = 12345
    
    @user.expect(:id, user_id)
    @user.expect(:dm, @dm_channel)
    
    message = Minitest::Mock.new
    message.expect(:id, 1)
    
    @dm_channel.expect(:id, 999)
    @dm_channel.expect(:send_message, message, [String])
    
    # Call the method
    result = @plugin.queue_keep_alive(@user, "Test Match", "queue-1")
    
    # Verify expectations
    assert result, "Should return true when DM is sent"
    @user.verify
    @dm_channel.verify
    message.verify
    
    # Verify state store
    assert @plugin.has_pending_notifications?(user_id)
    assert_equal 1, @plugin.pending_notification_count(user_id)
  end
  
  def test_pre_game_ready_check_sends_notification
    # Setup mocks
    user_id = 12345
    
    @user.expect(:id, user_id)
    @user.expect(:dm, @dm_channel)
    
    message = Minitest::Mock.new
    message.expect(:id, 1)
    
    @dm_channel.expect(:id, 999)
    @dm_channel.expect(:send_message, message, [String])
    
    # Call the method
    result = @plugin.pre_game_ready_check(@user, "match-1", { map: "cp_badlands" })
    
    # Verify expectations
    assert result, "Should return true when DM is sent"
    @user.verify
    @dm_channel.verify
    message.verify
    
    # Verify state store
    assert @plugin.has_pending_notifications?(user_id)
    assert_equal 1, @plugin.pending_notification_count(user_id)
  end
  
  def test_clear_notifications_removes_user_state
    # Setup state
    user_id = 12345
    
    @user.expect(:id, user_id)
    @user.expect(:dm, @dm_channel)
    
    message = Minitest::Mock.new
    message.expect(:id, 1)
    
    @dm_channel.expect(:id, 999)
    @dm_channel.expect(:send_message, message, [String])
    
    # Add a notification
    @plugin.queue_keep_alive(@user, "Test Match", "queue-1")
    
    # Verify it exists
    assert @plugin.has_pending_notifications?(user_id)
    
    # Clear it
    result = @plugin.clear_notifications(user_id)
    
    # Verify it's gone
    assert result, "Should return true when notifications are cleared"
    refute @plugin.has_pending_notifications?(user_id)
    assert_equal 0, @plugin.pending_notification_count(user_id)
  end
  
  def test_role_retention_check_disabled_by_default
    # Setup mocks
    user_id = 12345
    @user.expect(:id, user_id)
    
    # Call the method
    result = @plugin.role_retention_check(@user, "Member")
    
    # Verify expectations
    refute result, "Should return false when trigger is disabled"
    
    # Verify state store
    refute @plugin.has_pending_notifications?(user_id)
  end
  
  def test_max_pending_notifications_per_user
    # Setup config with smaller max
    @plugin.instance_variable_set(:@config, @config.merge(max_pending_per_user: 2))
    
    # Setup mocks
    user_id = 12345
    
    @user.expect(:id, user_id)
    @user.expect(:dm, @dm_channel).times(2)
    
    message = Minitest::Mock.new
    message.expect(:id, 1)
    message.expect(:id, 2)
    
    @dm_channel.expect(:id, 999).times(2)
    @dm_channel.expect(:send_message, message, [String]).times(2)
    
    # Call methods to create 2 notifications
    @plugin.queue_keep_alive(@user, "Test Match 1", "queue-1")
    @plugin.pre_game_ready_check(@user, "match-1", { map: "cp_badlands" })
    
    # Try to add a third
    # Enable role retention first
    @plugin.instance_variable_get(:@config)[:triggers][:role_retention] = true
    
    # This shouldn't create a notification
    result = @plugin.role_retention_check(@user, "Member")
    
    # Verify expectations
    refute result, "Should return false when max notifications reached"
    
    # Verify state store
    assert_equal 2, @plugin.pending_notification_count(user_id)
  end
  
  def test_expiration_removes_notification
    # Setup mocks
    user_id = 12345
    
    @user.expect(:id, user_id)
    @user.expect(:dm, @dm_channel).times(2) # One for notification, one for removal
    
    message = Minitest::Mock.new
    message.expect(:id, 1)
    
    @dm_channel.expect(:id, 999)
    @dm_channel.expect(:send_message, message, [String]).times(2) # Notification + removal
    
    # Setup short timeout
    @plugin.instance_variable_get(:@config)[:timeout_seconds][:match_queue] = 1
    
    # Send notification
    @plugin.queue_keep_alive(@user, "Test Match", "queue-1")
    
    # Verify it exists
    assert @plugin.has_pending_notifications?(user_id)
    
    # Wait for it to expire
    sleep 1.5
    
    # Force expiration check
    @plugin.send(:check_expirations)
    
    # Verify it's gone
    refute @plugin.has_pending_notifications?(user_id)
  end
end
