require 'spec_helper'
require_relative '../bot/services/notification_agent'
require_relative '../bot/services/super_loader'

RSpec.describe NotificationAgent do
  # Test doubles
  let(:logger) { instance_double(Logger, info: nil, error: nil, warn: nil) }
  let(:discord) { double('Discord', get_user: nil, get_channel: nil, on: nil) }
  let(:database) { double('Database', log_event: nil) }
  let(:config_manager) { double('ConfigManager', get_config: {}) }
  let(:agent_manager) { double('AgentManager', emit: nil, get_command_registry: nil) }
  let(:user_id) { '123456789' }
  
  before do
    # Stub Discord event handlers
    allow(discord).to receive(:on).with(any_args).and_return(nil)
    allow(discord).to receive(:on).with('messageCreate').and_yield(double('Message', 
      author: double('Author', id: user_id, bot: false),
      channel: double('Channel', type: 'dm'),
      content: '!ready'
    ))
  end
  
  let(:dependencies) do
    {
      logger: logger,
      discord: discord,
      database: database,
      config_manager: config_manager,
      agent_manager: agent_manager
    }
  end
  
  let(:default_config) do
    {
      'enabled' => true,
      'triggers' => {
        'match_queue' => { 'enabled' => true, 'tier' => 0 },
        'pre_game' => { 'enabled' => true, 'tier' => 0 },
        'role_retention' => { 'enabled' => true, 'tier' => 1 }
      },
      'timeout_seconds' => {
        'match_queue' => 300,
        'pre_game' => 120,
        'role_retention' => 86400
      }
    }
  end
  
  subject(:agent) { described_class.new({ skip_expiry_checker: true }, dependencies) }
  
  before do
    allow(config_manager).to receive(:get_config).with('notification').and_return(default_config)
  end

  describe '#initialization' do
    it 'initializes without error' do
      expect { agent }.not_to raise_error
    end
    
    it 'loads configuration' do
      expect(agent.config).to include('enabled' => true)
    end
  end

  describe '#send_notification' do
    let(:user_id) { '123456789' }
    let(:user) { double('User', send: nil, id: user_id) }
    let(:sent_message) { double('Message', id: 'msg1') }
    
    before do
      allow(discord).to receive(:get_user).and_return(user)
      allow(user).to receive(:send).and_return(sent_message)
    end

    context 'with match_queue notification' do
      it 'sends a match queue notification' do
        expect(user).to receive(:send).with(/Queue Keep-Alive/)
        agent.send_notification(user_id, 'match_queue', { match_name: 'Test Match' })
      end
      
      it 'stores the notification in state' do
        agent.send_notification(user_id, 'match_queue', { match_name: 'Test Match' })
        expect(agent.state_store[user_id]).to have_key('match_queue')
      end
    end
    
    context 'with pre_game notification' do
      it 'sends a pre-game notification' do
        expect(user).to receive(:send).with(/Match Ready!/)
        agent.send_notification(user_id, 'pre_game', { match_name: 'Test Match' })
      end
    end
  end

  describe '#handle_response' do
    let(:user_id) { '123456789' }
    
    before do
      # Create a properly formatted state store with all required fields
      # IMPORTANT: The state store key must be a string, not a symbol
      test_state = {}
      test_state[user_id] = {
        'match_queue' => {
          context: { match_name: 'Test Match', queue_id: 'q1' },
          expires_at: (Time.now.to_i * 1000) + 300000,
          message_id: 'msg1',
          sent_at: Time.now.to_i * 1000,
          tier: 0
        }
      }
      agent.instance_variable_set(:@state_store, test_state)
      
      # Initialize response handlers hash
      agent.instance_variable_set(:@response_handlers, {})
      
      # Ensure agent_manager is properly stubbed
      allow(agent_manager).to receive(:emit).with(any_args)
    end

    it 'handles ready response for match_queue' do
      expect(agent_manager).to receive(:emit).with('queue:keep_alive_confirmed', any_args)
      expect(agent.handle_response(user_id, '!ready')).to be true
    end
    
    it 'handles cancel response' do
      expect(agent_manager).to receive(:emit).with('queue:keep_alive_canceled', any_args)
      expect(agent.handle_response(user_id, '!cancel')).to be true
    end
  end

  describe '#check_expirations' do
    let(:user_id) { '123456789' }
    let(:expired_time) { (Time.now.to_i * 1000) - 1000 }
    let(:future_time) { (Time.now.to_i * 1000) + 300000 }
    
    before do
      # Create a properly formatted state store with all required fields
      test_state = {}
      test_state[user_id] = {
        'expired_notification' => {
          context: { data: 'test' },
          expires_at: expired_time,
          message_id: 'msg2',
          sent_at: Time.now.to_i * 1000 - 10000,
          tier: 0
        },
        'active_notification' => {
          context: { data: 'test' },
          expires_at: future_time,
          message_id: 'msg3',
          sent_at: Time.now.to_i * 1000,
          tier: 1
        }
      }
      agent.instance_variable_set(:@state_store, test_state)
      
      # Initialize response handlers hash
      agent.instance_variable_set(:@response_handlers, {})
      
      # Allow emit for any event
      allow(agent).to receive(:emit).with(any_args)
    end

    it 'removes expired notifications' do
      agent.check_expirations
      expect(agent.state_store[user_id]).not_to have_key('expired_notification')
      expect(agent.state_store[user_id]).to have_key('active_notification')
    end
    
    it 'emits expired event for expired notifications' do
      expect(agent).to receive(:emit).with('notification:expired', hash_including(type: 'expired_notification'))
      agent.check_expirations
    end

    it 'removes expired notifications' do
      agent.check_expirations
      expect(agent.state_store[user_id]).not_to have_key('expired_notification')
      expect(agent.state_store[user_id]).to have_key('active_notification')
    end
    
    it 'emits expired event for expired notifications' do
      expect(agent).to receive(:emit).with('notification:expired', any_args)
      agent.check_expirations
    end
  end

  describe 'SuperLoader integration' do
    let(:superloader) { instance_double(SuperLoader) }
    let(:test_user_id) { '123456789' }
    let(:user) { double('User', send: double('Message', id: 'msg1')) }
    
    before do
      # Setup SuperLoader with required stubs
      allow(SuperLoader).to receive(:new).and_return(superloader)
      allow(superloader).to receive(:on).with(any_args)
      allow(superloader).to receive(:has_step?).and_return(true)
      allow(superloader).to receive(:exec_step).and_return({ success: true })
      
      # Setup config
      allow(config_manager).to receive(:get_config).with('notification').and_return(
        {
          'enabled' => true,
          'triggers' => {
            'match_queue' => { 'enabled' => true, 'tier' => 0 },
            'pre_game' => { 'enabled' => true, 'tier' => 0 }
          }
        }
      )
      
      # Setup Discord user for sending messages
      allow(discord).to receive(:get_user).with(test_user_id).and_return(user)
    end

    describe '#send_notification with preprocessing' do
      it 'calls SuperLoader for preprocessing' do
        expect(superloader).to receive(:exec_step).with(
          'preprocess_notification',
          hash_including(userId: test_user_id, type: 'match_queue')
        )
        
        agent.send_notification(test_user_id, 'match_queue', { match_name: 'Test Match' })
      end

      it 'respects preprocessing skip directive' do
        allow(superloader).to receive(:exec_step).and_return({ skip: true, result: true })
        expect(agent.send_notification(test_user_id, 'match_queue', {})).to be true
      end
    end

    describe '#check_expirations with SuperLoader' do
      before do
        # Setup state store with notifications
        agent.instance_variable_set(:@state_store, {
          test_user_id => {
            'match_queue' => {
              context: { match_name: 'Test Match' },
              expires_at: (Time.now.to_i * 1000) - 1000,
              message_id: 'msg1',
              sent_at: Time.now.to_i * 1000 - 10000,
              tier: 0
            }
          }
        })
      end
      
      it 'delegates to SuperLoader expiration handler' do
        allow(superloader).to receive(:exec_step).and_return({ handled: true })
        expect(superloader).to receive(:exec_step).with(
          'check_expirations',
          hash_including(:stateStore)
        )
        agent.check_expirations
      end
    end
  end
end
