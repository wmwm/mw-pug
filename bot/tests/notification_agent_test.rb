require 'minitest/autorun'
require 'minitest/mock'
require_relative '../bot/services/notification_agent'
require_relative '../bot/services/super_loader'

class NotificationAgentTest < Minitest::Test
  def setup
    # Mock dependencies
    @discord = Minitest::Mock.new
    @database = Minitest::Mock.new
    @config_manager = Minitest::Mock.new
    @agent_manager = Minitest::Mock.new
    @logger = Logger.new(nil) # Suppress logging during tests
    
    # Mock configuration
    @config = {
      'enabled' => true,
      'triggers' => {
        'match_queue' => { 'enabled' => true, 'tier' => 0 },
        'pre_game' => { 'enabled' => true, 'tier' => 0 },
        'role_retention' => { 'enabled' => true, 'tier' => 1 }
      },
      'timeout_seconds' => {
        'match_queue' => 300,
        'pre_game' => 60,
        'role_retention' => 86400
      },
      'dm_templates' => {
        'match_queue' => '**Queue Keep-Alive** for {match_name} - Reply with `!ready` to stay in queue!',
        'pre_game' => '**Match Ready!** Your match {match_name} is about to start. Reply with `!ready` to confirm.',
        'role_retention' => '**Role Retention** - Reply with `!active` to keep your {role_name} role.'
      },
      'fallback_channel_id' => 'fallback_channel',
      'max_pending_per_user' => 3
    }
    
    @config_manager.expect(:get_config, @config, ['notification'])
    @config_manager.expect(:config_path, './config')
    
    # Create agent with dependencies
    @dependencies = {
      discord: @discord,
      database: @database,
      config_manager: @config_manager,
      logger: @logger
    }
    
    @agent = NotificationAgent.new({}, @dependencies)
  end
  
  def test_initialization
    @agent_manager.expect(:get_command_registry, nil)
    
    # Initialize agent
    @agent.initialize(@agent_manager)
    
    assert @agent.superloader.is_a?(SuperLoader)
    assert @agent.config.is_a?(Hash)
    assert @agent.config['enabled']
  end
  
  def test_send_notification
    user_id = '123456789'
    type = 'match_queue'
    context = { match_name: 'Test Match', queue_id: 'test-queue-1' }
    
    # Mock Discord user
    user = Minitest::Mock.new
    message = Minitest::Mock.new
    
    message.expect(:id, 'message1')
    user.expect(:send, message, [String])
    
    # Mock Discord
    @discord.expect(:get_user, user, [user_id])
    
    # Run test
    result = @agent.send_notification(user_id, type, context)
    
    assert result
    assert @agent.state_store.key?(user_id)
    assert @agent.state_store[user_id].key?(type)
    assert_equal context[:match_name], @agent.state_store[user_id][type][:context][:match_name]
    
    # Verify mocks
    user.verify
    message.verify
    @discord.verify
  end
  
  def test_send_queue_keep_alive
    user_id = '123456789'
    match_name = 'Test Match'
    queue_id = 'test-queue-1'
    
    # Mock Discord user
    user = Minitest::Mock.new
    message = Minitest::Mock.new
    
    message.expect(:id, 'message1')
    user.expect(:send, message, [String])
    
    # Mock Discord
    @discord.expect(:get_user, user, [user_id])
    
    # Run test
    result = @agent.send_queue_keep_alive(user_id, match_name, queue_id)
    
    assert result
    assert @agent.state_store.key?(user_id)
    assert @agent.state_store[user_id].key?('match_queue')
    assert_equal match_name, @agent.state_store[user_id]['match_queue'][:context][:match_name]
    assert_equal queue_id, @agent.state_store[user_id]['match_queue'][:context][:queue_id]
    
    # Verify mocks
    user.verify
    message.verify
    @discord.verify
  end
  
  def test_clear_notification
    # Setup a notification first
    user_id = '123456789'
    type = 'match_queue'
    
    # Mock state
    @agent.state_store[user_id] = {
      type => {
        context: { match_name: 'Test Match' },
        expires_at: Time.now.to_i * 1000 + 300_000
      }
    }
    
    # Clear notification
    result = @agent.clear_notification(user_id, type)
    
    assert result
    assert !@agent.state_store.key?(user_id)
  end
  
  def test_handle_response
    user_id = '123456789'
    type = 'match_queue'
    context = { match_name: 'Test Match', queue_id: 'test-queue-1' }
    
    # Setup notification state
    @agent.state_store[user_id] = {
      type => {
        context: context,
        expires_at: Time.now.to_i * 1000 + 300_000
      }
    }
    
    # Test ready response
    result = @agent.handle_response(user_id, '!ready')
    
    assert result
    assert !@agent.state_store.key?(user_id)
  end
  
  def test_get_notification_tier
    assert_equal 0, @agent.get_notification_tier('match_queue')
    assert_equal 0, @agent.get_notification_tier('pre_game')
    assert_equal 1, @agent.get_notification_tier('role_retention')
    assert_equal 2, @agent.get_notification_tier('unknown_type')
  end
  
  def test_check_expirations
    user_id = '123456789'
    type = 'match_queue'
    
    # Setup an expired notification
    @agent.state_store[user_id] = {
      type => {
        context: { match_name: 'Test Match' },
        expires_at: Time.now.to_i * 1000 - 10_000 # 10 seconds in the past
      }
    }
    
    # Check expirations
    @agent.check_expirations
    
    # Notification should be removed
    assert !@agent.state_store.key?(user_id)
  end
  
  def test_integration_with_superloader
    # Create a minimal SuperLoader for testing
    class TestSuperLoader < SuperLoader
      attr_reader :steps_called
      
      def initialize(options = {}, deps = {})
        super
        @steps_called = []
      end
      
      def has_step?(step_name)
        true
      end
      
      def exec_step(step_name, params)
        @steps_called << { step: step_name, params: params }
        
        case step_name
        when 'preprocess_notification'
          { context: params[:context].merge(processed: true) }
        when 'check_expirations'
          { handled: true }
        when 'queue_keep_alive_processing'
          { processed: true, success: true }
        else
          {}
        end
      end
    end
    
    # Replace agent's SuperLoader with test version
    @agent.instance_variable_set(:@superloader, TestSuperLoader.new({}, @dependencies))
    
    # Test sending notification with preprocessing
    user_id = '123456789'
    type = 'match_queue'
    context = { match_name: 'Test Match', queue_id: 'test-queue-1' }
    
    # Mock Discord user
    user = Minitest::Mock.new
    message = Minitest::Mock.new
    
    message.expect(:id, 'message1')
    user.expect(:send, message, [String])
    
    # Mock Discord
    @discord.expect(:get_user, user, [user_id])
    
    # Send notification
    result = @agent.send_notification(user_id, type, context)
    
    assert result
    superloader = @agent.instance_variable_get(:@superloader)
    
    # Verify SuperLoader was called with preprocess_notification
    assert_equal 1, superloader.steps_called.size
    assert_equal 'preprocess_notification', superloader.steps_called[0][:step]
    assert_equal user_id, superloader.steps_called[0][:params][:userId]
    assert_equal type, superloader.steps_called[0][:params][:type]
    
    # Verify context was processed
    assert @agent.state_store[user_id][type][:context][:processed]
    
    # Verify mocks
    user.verify
    message.verify
    @discord.verify
  end
end
