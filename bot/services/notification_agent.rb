require 'logger'
require 'json'
require 'time'
require_relative 'super_loader'

# NotificationAgent
#
# Manages player-specific notifications with a tiered delivery system.
# Handles queue keep-alives, pre-game alerts, role retention, and other notifications.
# Integrates with SuperLoader for YAML-driven configurations and advanced notification processing.
class NotificationAgent
  attr_reader :config, :state_store, :superloader
  
  # Creates a new NotificationAgent instance
  # @param options [Hash] Configuration options
  # @param dependencies [Hash] Dependencies injected into the agent
  def initialize(options = {}, dependencies = {})
    @options = options
    @dependencies = dependencies || {}
    
    # Initialize logger
    @logger = @dependencies[:logger] || Logger.new(STDOUT)
    
    # Initialize configuration
    @config_manager = @dependencies[:config_manager]
    @config = {
      'enabled' => true,
      'triggers' => {},
      'timeout_seconds' => {},
      'dm_templates' => {}
    }
    
    # Initialize state store for tracking active notifications
    @state_store = {}
    
    # Command registry
    @commands = {}
    
    # Event listeners
    @event_listeners = {
      'notification:sent' => [],
      'notification:expired' => [],
      'notification:responded' => [],
      'notification:cleared' => []
    }
    
    # Notification response handlers
    @response_handlers = {}
    
    # Last activity timestamps
    @last_activity = {}
    
    @initialized = false
    
    @logger.info('NotificationAgent initialized')
  end
  
  # Initialize the notification agent
  # @param agent_manager [Object] Reference to the agent manager
  # @return [Boolean] True if initialization was successful
  def initialize(options = {}, dependencies = {})
    @options = options
    @dependencies = dependencies || {}
    @agent_manager = @dependencies[:agent_manager]
    
    # Initialize logger
    @logger = @dependencies[:logger] || Logger.new(STDOUT)
    
    # Initialize configuration
    @config = {
      'enabled' => true,
      'triggers' => {},
      'timeout_seconds' => {},
      'dm_templates' => {}
    }
    
    # Initialize state store for tracking active notifications
    @state_store = {}
    
    # Event listeners
    @event_listeners = {
      'notification:sent' => [],
      'notification:expired' => [],
      'notification:responded' => [],
      'notification:cleared' => []
    }
    
    # Last activity timestamps
    @last_activity = {}
    
    begin
      # Load configuration
      load_config
      
      # Register commands
      register_commands
      
      # Initialize SuperLoader
      init_super_loader
      
      # Register event handlers
      register_event_handlers
      
      # Start notification expiry checker
      start_expiry_checker if !options[:skip_expiry_checker]
      
      @initialized = true
      @logger.info('NotificationAgent fully initialized')
    rescue => error
      @logger.error("NotificationAgent initialization failed: #{error.message}")
    end
  end
  
  # Register an event listener
  # @param event_name [String] Name of the event
  # @param block [Proc] Block to execute when event is triggered
  def on(event_name, &block)
    return unless @event_listeners.key?(event_name)
    @event_listeners[event_name] << block
  end
  
  # Remove an event listener
  # @param event_name [String] Name of the event
  # @param block [Proc] Block to remove
  def off(event_name, &block)
    return unless @event_listeners.key?(event_name)
    @event_listeners[event_name].delete(block)
  end
  
  # Emit an event
  # @param event_name [String] Name of the event
  # @param data [Hash] Data to pass to the event listeners
  def emit(event_name, data = {})
    return unless @event_listeners.key?(event_name)
    @event_listeners[event_name].each { |listener| listener.call(data) }
  end
  
  # Get the notification tier for a specific type
  # @param type [String] Notification type
  # @return [Integer] Notification tier (0-2)
  def get_notification_tier(type)
    if @config['triggers'] && @config['triggers'][type] && @config['triggers'][type]['tier'].is_a?(Numeric)
      @config['triggers'][type]['tier']
    elsif type == 'match_queue' || type == 'pre_game'
      0 # Default to Critical tier for game-related notifications
    elsif type == 'role_retention' || type == 'match_result'
      1 # Default to Important tier for status-related notifications
    else
      2 # Default to Informational tier for all others
    end
  end
  
  # Send a notification to a user
  # @param user_id [String] Discord user ID
  # @param type [String] Notification type
  # @param context [Hash] Context data for the notification
  # @return [Boolean] True if notification was sent
  def send_notification(user_id, type, context = {})
    # Check if notifications are enabled
    return false unless @config['enabled']
    
    # Check if this notification type is enabled
    return false unless notification_type_enabled?(type)
    
    # Create a copy of the context to avoid modification of the original
    notification_context = context.dup
    
    # Preprocess notification if SuperLoader is available
    if @superloader && @superloader.has_step?('preprocess_notification')
      begin
        result = @superloader.exec_step('preprocess_notification', {
          userId: user_id,
          type: type,
          context: notification_context
        })
        
        # Skip notification if preprocessing indicates
        if result && result[:skip]
          @logger.info("Notification skipped by preprocessor: #{type} for #{user_id}")
          return result[:result].nil? ? true : result[:result]
        end
        
        # Update context if provided by preprocessor
        notification_context = result[:context] if result && result[:context]
      rescue => error
        @logger.error("Notification preprocessing failed: #{error.message}")
      end
    end
    
    # Check for max pending notifications per user
    max_pending = @config['max_pending_per_user'] || 5
    if user_notification_count(user_id) >= max_pending
      @logger.info("Max pending notifications reached for #{user_id}")
      return false
    end
    
    # Get timeout for this notification type
    timeout_seconds = @config.dig('timeout_seconds', type) || 0
    
    # Create notification message
    message = format_notification(type, notification_context)
    
    # Calculate expiration time
    expires_at = timeout_seconds > 0 ? (Time.now.to_i * 1000 + (timeout_seconds * 1000)) : 0
    
    # Try to send the notification via DM
    sent = false
    fallback_used = false
    message_id = nil
    
    begin
      # Get Discord user
      user = @dependencies[:discord].get_user(user_id)
      
      if user
        # Send DM
        result = user.send(message)
        message_id = result.id
        sent = true
      else
        @logger.warn("User #{user_id} not found")
        sent = false
      end
    rescue => error
      @logger.error("Failed to send DM to #{user_id}: #{error.message}")
      sent = false
    end
    
    # Use fallback channel if DM failed
    if !sent
      begin
        fallback_channel_id = get_fallback_channel_id(type)
        
        if fallback_channel_id
          channel = @dependencies[:discord].get_channel(fallback_channel_id)
          
          if channel
            # Get username for mention
            username = @dependencies[:discord].get_username(user_id)
            mention = username ? "<@#{user_id}> (#{username})" : "<@#{user_id}>"
            
            # Send to fallback channel with mention
            result = channel.send("#{mention}: #{message}")
            message_id = result.id
            sent = true
            fallback_used = true
          end
        end
      rescue => error
        @logger.error("Failed to send fallback notification: #{error.message}")
      end
    end
    
    # If the notification was sent, store it
    if sent
      # Store notification in state
      store_notification(user_id, type, {
        message_id: message_id,
        context: notification_context,
        expires_at: expires_at,
        sent_at: Time.now.to_i * 1000,
        fallback: fallback_used,
        tier: get_notification_tier(type)
      })
      
      # Log notification
      log_notification(user_id, type, notification_context)
      
      # Emit notification:sent event
      emit('notification:sent', {
        user_id: user_id,
        type: type,
        context: notification_context,
        expires_at: expires_at,
        fallback: fallback_used
      })
      
      # Register response handler if needed
      register_response_handler(user_id, type, notification_context) if needs_response?(type)
      
      return true
    end
    
    false
  end
  
  # Send queue keep-alive notification
  # @param user_id [String] Discord user ID
  # @param match_name [String] Name of the match
  # @param queue_id [String] ID of the queue
  # @return [Boolean] True if notification was sent
  def send_queue_keep_alive(user_id, match_name, queue_id)
    # Create notification context
    context = {
      match_name: match_name,
      queue_id: queue_id
    }
    
    # Check if we should process this with SuperLoader
    if @superloader && @superloader.has_step?('queue_keep_alive_processing')
      begin
        result = @superloader.exec_step('queue_keep_alive_processing', {
          userId: user_id,
          context: context
        })
        
        # Return if processed by SuperLoader
        if result && result[:processed]
          @logger.info("Queue keep-alive processed by SuperLoader for #{user_id}")
          return result[:success] || true
        end
      rescue => error
        @logger.error("Queue keep-alive processing error: #{error.message}")
      end
    end
    
    # Send as normal notification
    send_notification(user_id, 'match_queue', context)
  end
  
  # Send pre-game notification
  # @param user_id [String] Discord user ID
  # @param match_name [String] Name of the match
  # @param match_id [String] ID of the match
  # @return [Boolean] True if notification was sent
  def send_pre_game(user_id, match_name, match_id)
    # Create notification context
    context = {
      match_name: match_name,
      match_id: match_id
    }
    
    # Send notification
    send_notification(user_id, 'pre_game', context)
  end
  
  # Send role retention notification
  # @param user_id [String] Discord user ID
  # @param role_name [String] Name of the role
  # @param days_remaining [Integer] Days remaining before role expires
  # @return [Boolean] True if notification was sent
  def send_role_retention(user_id, role_name, days_remaining)
    # Create notification context
    context = {
      role_name: role_name,
      days_remaining: days_remaining
    }
    
    # Send notification
    send_notification(user_id, 'role_retention', context)
  end
  
  # Send a custom notification
  # @param user_id [String] Discord user ID
  # @param type [String] Notification type
  # @param context [Hash] Context data for the notification
  # @return [Boolean] True if notification was sent
  def send_custom_notification(user_id, type, context = {})
    # Check if this is a known notification type
    return false unless notification_type_enabled?(type)
    
    # Send notification
    send_notification(user_id, type, context)
  end
  
  # Handle a user response to a notification
  # @param user_id [String] Discord user ID
  # @param message [String] User's response message
  # @return [Boolean] True if the response was handled
  def handle_response(user_id, message)
    # Check if there are any active notifications for this user
    user_notifications = @state_store[user_id]
    return false unless user_notifications
    
    # Clean the message
    clean_message = message.to_s.strip.downcase
    
    # Check for common response keywords
    handled = false
    
    case clean_message
    when /^!ready$/, /^ready$/, /^y$/
      # Handle ready responses (for match_queue, pre_game)
      handled = handle_ready_response(user_id)
      
    when /^!active$/, /^active$/, /^keep$/, /^k$/
      # Handle active responses (for role_retention)
      handled = handle_active_response(user_id)
      
    when /^!cancel$/, /^cancel$/, /^leave$/, /^n$/
      # Handle cancel responses (for any notification)
      handled = handle_cancel_response(user_id)
      
    else
      # Check for custom response handlers
      user_notifications.each do |type, data|
        handler = @response_handlers["#{user_id}:#{type}"]
        
        if handler && handler.call(user_id, type, clean_message, data[:context])
          clear_notification(user_id, type)
          handled = true
          break
        end
      end
    end
    
    # Log response
    if handled
      @logger.info("Handled notification response from #{user_id}: #{message}")
      
      # Update last activity timestamp
      @last_activity[user_id] = Time.now.to_i * 1000
    end
    
    handled
  end
  
  # Clear a notification for a user
  # @param user_id [String] Discord user ID
  # @param type [String] Notification type
  # @return [Boolean] True if notification was cleared
  def clear_notification(user_id, type)
    # Check if notification exists
    user_notifications = @state_store[user_id]
    return false unless user_notifications.is_a?(Hash)
    return false unless user_notifications.key?(type)

    # Remove the notification
    notification = user_notifications.delete(type)
    return false unless notification

    # Remove the user if they have no more notifications
    @state_store.delete(user_id) if user_notifications.empty?

    # Remove any response handlers
    @response_handlers.delete("#{user_id}:#{type}")

    # Emit notification:cleared event only if context exists
    if notification.is_a?(Hash) && notification.key?(:context)
      emit('notification:cleared', {
        user_id: user_id,
        type: type,
        context: notification[:context]
      })
    end

    # Log notification cleared
    @logger.info("Cleared notification #{type} for #{user_id}")

    true
  end
  
  # Check notifications for expirations
  def check_expirations
    now = Time.now.to_i * 1000
    
    # Check if we should use SuperLoader for expirations
    if @superloader && @superloader.has_step?('check_expirations')
      begin
        result = @superloader.exec_step('check_expirations', {
          stateStore: @state_store
        })
        
        # Return if handled by SuperLoader
        if result && result[:handled]
          return
        end
      rescue => error
        @logger.error("Expiration checking error in SuperLoader: #{error.message}")
      end
    end
    
    # Standard expiration check
    expired_notifications = []
    
    # Find expired notifications
    @state_store.each do |user_id, user_notifications|
      user_notifications.each do |type, data|
        # Skip notifications with no expiry
        next if data[:expires_at] == 0
        
        # Check if expired
        if data[:expires_at] <= now
          expired_notifications << {
            user_id: user_id,
            type: type,
            context: data[:context]
          }
        end
      end
    end
    
    # Process expired notifications
    expired_notifications.each do |notification|
      # Clear the notification
      clear_notification(notification[:user_id], notification[:type])
      
      # Emit notification:expired event
      emit('notification:expired', notification)
      
      # Log expiration
      @logger.info("Notification #{notification[:type]} expired for #{notification[:user_id]}")
    end
  end
  
  # Execute a YAML upgrade sequence
  # @param filename [String] Name of the YAML file
  # @return [Hash] Result of the upgrade
  def execute_upgrade(filename)
    return { success: false, error: 'SuperLoader not initialized' } unless @superloader
    
    begin
      # Execute the upgrade
      result = @superloader.execute_upgrade(filename)
      
      # Refresh configuration if upgrade was successful
      refresh_configuration(result) if result[:success]
      
      result
    rescue => error
      @logger.error("Error executing upgrade: #{error.message}")
      { success: false, error: error.message }
    end
  end
  
  # Refresh configuration after an upgrade
  # @param upgrade_result [Hash] Result of the upgrade
  def refresh_configuration(upgrade_result = nil)
    begin
      # Reload configuration
      load_config
      
      # Log refresh
      @logger.info('Configuration refreshed')
      
      true
    rescue => error
      @logger.error("Error refreshing configuration: #{error.message}")
      false
    end
  end
  
  private
  
  # Load configuration
  def load_config
    if @config_manager
      begin
        # Load notification configuration
        notification_config = @config_manager.get_config('notification') || {}
        
        # Update configuration
        @config.merge!(notification_config)
        
        @logger.info('Notification configuration loaded')
      rescue => error
        @logger.error("Error loading configuration: #{error.message}")
      end
    end
  end
  
  # Register commands
  def register_commands
    command_registry = @agent_manager&.get_command_registry
    return unless command_registry
    
    # Register notification status command
    command_registry.register_command({
      name: 'notifications',
      description: 'Check or manage your notification status',
      options: [
        { name: 'status', description: 'Show your notification status', type: 'boolean' },
        { name: 'clear', description: 'Clear your notifications', type: 'boolean' }
      ],
      handler: method(:handle_notifications_command)
    })
  end
  
  # Initialize SuperLoader
  def init_super_loader
    begin
      # Create SuperLoader instance
      @superloader = SuperLoader.new({
        config_path: @config_manager ? @config_manager.config_path : File.join(Dir.pwd, 'config')
      }, {
        logger: @logger,
        discord: @dependencies[:discord],
        database: @dependencies[:database],
        config_manager: @config_manager,
        agent_manager: @agent_manager,
        notification_agent: self
      })
      
      # Register event listeners
      @superloader.on('upgrade:start') do |data|
        @logger.info("SuperLoader upgrade started: #{data[:config]['description']}")
      end
      
      @superloader.on('upgrade:complete') do |data|
        @logger.info("SuperLoader upgrade completed with #{data[:results].length} steps")
      end
      
      @superloader.on('upgrade:error') do |data|
        @logger.error("SuperLoader upgrade error: #{data[:error]}")
      end
      
      @logger.info('SuperLoader initialized')
    rescue => error
      @logger.error("Error initializing SuperLoader: #{error.message}")
    end
  end
  
  # Register event handlers
  def register_event_handlers
    discord = @dependencies[:discord]
    return unless discord
    
    # Register message handler for DMs
    discord.on('messageCreate') do |message|
      # Only handle DM messages that aren't from bots
      if message.channel.type == 'dm' && !message.author.bot
        handle_response(message.author.id, message.content)
      end
    end
  end
  
  # Start notification expiry checker
  def start_expiry_checker
    # Create a thread to check for expired notifications
    @expiry_thread = Thread.new do
      begin
        # Check every 5 seconds
        loop do
          check_expirations
          sleep 5
        end
      rescue => error
        @logger.error("Error in expiry checker: #{error.message}")
      end
    end
  end
  
  # Check if a notification type is enabled
  # @param type [String] Notification type
  # @return [Boolean] True if enabled
  def notification_type_enabled?(type)
    trigger = @config.dig('triggers', type)
    return trigger == true if [true, false].include?(trigger)
    return trigger['enabled'] == true if trigger.is_a?(Hash) && trigger.key?('enabled')
    
    # Default for known core notification types
    return true if ['match_queue', 'pre_game', 'role_retention'].include?(type)
    
    false
  end
  
  # Format a notification message
  # @param type [String] Notification type
  # @param context [Hash] Context data
  # @return [String] Formatted message
  def format_notification(type, context)
    template = @config.dig('dm_templates', type)
    
    # Default templates for core notification types
    unless template
      case type
      when 'match_queue'
        template = '**Queue Keep-Alive** for {match_name} - Reply with `!ready` to stay in queue!'
      when 'pre_game'
        template = '**Match Ready!** Your match {match_name} is about to start. Reply with `!ready` to confirm.'
      when 'role_retention'
        template = '**Role Retention** - Reply with `!active` to keep your {role_name} role.'
      else
        template = "Notification: #{type}"
      end
    end
    
    # Replace template variables
    message = template.gsub(/\{([^}]+)\}/) do |match|
      key = $1
      context[key.to_sym] || context[key] || match
    end
    
    message
  end
  
  # Get the fallback channel ID for a notification
  # @param type [String] Notification type
  # @return [String, nil] Channel ID or nil
  def get_fallback_channel_id(type)
    tier = get_notification_tier(type)
    
    # Try tier-specific fallback channel
    fallback_id = @config["fallback_channel_tier#{tier}_id"]
    
    # Fall back to default fallback channel
    fallback_id ||= @config['fallback_channel_id']
    
    fallback_id
  end
  
  # Store a notification in the state store
  # @param user_id [String] Discord user ID
  # @param type [String] Notification type
  # @param data [Hash] Notification data
  def store_notification(user_id, type, data)
    # Initialize user if needed
    @state_store[user_id] ||= {}
    
    # Store notification
    @state_store[user_id][type] = data
  end
  
  # Log a notification
  # @param user_id [String] Discord user ID
  # @param type [String] Notification type
  # @param context [Hash] Context data
  def log_notification(user_id, type, context)
    # Log to console
    @logger.info("Sent notification #{type} to #{user_id}")
    
    # Log to database if available
    if @dependencies[:database] && @dependencies[:database].respond_to?(:log_event)
      @dependencies[:database].log_event(
        'notification',
        type,
        user_id,
        { context: context }
      )
    end
    
    # Log to audit channel if configured
    if @config['audit_log'] && @config['log_channel_id']
      begin
        channel = @dependencies[:discord].get_channel(@config['log_channel_id'])
        
        if channel
          # Format log message
          username = @dependencies[:discord].get_username(user_id)
          user_text = username ? "#{username} (#{user_id})" : user_id
          
          context_json = JSON.pretty_generate(context) rescue context.to_s
          
          log_message = "**Notification Log**\n" +
                        "> **Type:** #{type}\n" +
                        "> **User:** #{user_text}\n" +
                        "> **Time:** #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n" +
                        "> **Context:**\n```json\n#{context_json}\n```"
                        
          channel.send(log_message)
        end
      rescue => error
        @logger.error("Error logging to audit channel: #{error.message}")
      end
    end
  end
  
  # Register a response handler for a notification
  # @param user_id [String] Discord user ID
  # @param type [String] Notification type
  # @param context [Hash] Context data
  def register_response_handler(user_id, type, context)
    # Default handlers are implemented in handle_response
    # This is for custom handlers only
    
    # Example: Register a custom handler
    # @response_handlers["#{user_id}:#{type}"] = lambda do |user_id, type, message, context|
    #   # Custom handling logic
    #   true
    # end
  end
  
  # Check if a notification type requires a response
  # @param type [String] Notification type
  # @return [Boolean] True if response is required
  def needs_response?(type)
    case type
    when 'match_queue', 'pre_game', 'role_retention'
      true
    else
      false
    end
  end
  
  # Handle ready response
  # @param user_id [String] Discord user ID
  # @return [Boolean] True if handled
  def handle_ready_response(user_id)
    user_notifications = @state_store[user_id]
    return false unless user_notifications
    
    # Check for match_queue notification
    if user_notifications['match_queue']
      context = user_notifications['match_queue'][:context]
      
      # Emit notification:responded event
      emit('notification:responded', {
        user_id: user_id,
        type: 'match_queue',
        response: 'ready',
        context: context
      })
      
      # Clear the notification
      clear_notification(user_id, 'match_queue')
      
      # Emit queue:keep_alive_confirmed event
      @agent_manager&.emit('queue:keep_alive_confirmed', {
        user_id: user_id,
        queue_id: context[:queue_id],
        match_name: context[:match_name]
      })
      
      return true
    end
    
    # Check for pre_game notification
    if user_notifications['pre_game']
      context = user_notifications['pre_game'][:context]
      
      # Emit notification:responded event
      emit('notification:responded', {
        user_id: user_id,
        type: 'pre_game',
        response: 'ready',
        context: context
      })
      
      # Clear the notification
      clear_notification(user_id, 'pre_game')
      
      # Emit match:ready_confirmed event
      @agent_manager&.emit('match:ready_confirmed', {
        user_id: user_id,
        match_id: context[:match_id],
        match_name: context[:match_name]
      })
      
      return true
    end
    
    false
  end
  
  # Handle active response
  # @param user_id [String] Discord user ID
  # @return [Boolean] True if handled
  def handle_active_response(user_id)
    user_notifications = @state_store[user_id]
    return false unless user_notifications
    
    # Check for role_retention notification
    if user_notifications['role_retention']
      context = user_notifications['role_retention'][:context]
      
      # Emit notification:responded event
      emit('notification:responded', {
        user_id: user_id,
        type: 'role_retention',
        response: 'active',
        context: context
      })
      
      # Clear the notification
      clear_notification(user_id, 'role_retention')
      
      # Emit role:retention_confirmed event
      @agent_manager&.emit('role:retention_confirmed', {
        user_id: user_id,
        role_name: context[:role_name],
        days_remaining: context[:days_remaining]
      })
      
      return true
    end
    
    false
  end
  
  # Handle cancel response
  # @param user_id [String] Discord user ID
  # @return [Boolean] True if handled
  def handle_cancel_response(user_id)
    user_notifications = @state_store[user_id]
    return false unless user_notifications
    
    # Find the first notification to cancel
    type = user_notifications.keys.first
    return false unless type
    
    context = user_notifications[type][:context]
    
    # Emit notification:responded event
    emit('notification:responded', {
      user_id: user_id,
      type: type,
      response: 'cancel',
      context: context
    })
    
    # Clear the notification
    clear_notification(user_id, type)
    
    # Emit type-specific cancellation event
    case type
    when 'match_queue'
      @agent_manager&.emit('queue:keep_alive_canceled', {
        user_id: user_id,
        queue_id: context[:queue_id],
        match_name: context[:match_name]
      })
    when 'pre_game'
      @agent_manager&.emit('match:ready_canceled', {
        user_id: user_id,
        match_id: context[:match_id],
        match_name: context[:match_name]
      })
    when 'role_retention'
      @agent_manager&.emit('role:retention_canceled', {
        user_id: user_id,
        role_name: context[:role_name]
      })
    end
    
    true
  end
  
  # Handle notifications command
  # @param interaction [Object] Discord interaction
  def handle_notifications_command(interaction)
    user_id = interaction.user.id
    
    if interaction.options[:status]
      # Show notification status
      show_notification_status(interaction, user_id)
    elsif interaction.options[:clear]
      # Clear all notifications
      clear_all_notifications(interaction, user_id)
    else
      # Show help
      show_notification_help(interaction)
    end
  end
  
  # Show notification status
  # @param interaction [Object] Discord interaction
  # @param user_id [String] Discord user ID
  def show_notification_status(interaction, user_id)
    user_notifications = @state_store[user_id]
    
    if !user_notifications || user_notifications.empty?
      interaction.reply(content: "You don't have any active notifications.", ephemeral: true)
      return
    end
    
    # Build status message
    message = "**Your Active Notifications:**\n\n"
    
    user_notifications.each do |type, data|
      expires = data[:expires_at] > 0 ? Time.at(data[:expires_at] / 1000).strftime('%H:%M:%S') : 'Never'
      
      message += "> **#{type}**\n"
      message += "> Expires: #{expires}\n"
      
      # Add context summary if available
      if data[:context] && !data[:context].empty?
        context_summary = data[:context].map { |k, v| "#{k}: #{v}" }.join(', ')
        message += "> Context: #{context_summary}\n"
      end
      
      message += "\n"
    end
    
    # Add instructions
    message += "*Use `/notifications clear` to clear all notifications.*"
    
    interaction.reply(content: message, ephemeral: true)
  end
  
  # Clear all notifications
  # @param interaction [Object] Discord interaction
  # @param user_id [String] Discord user ID
  def clear_all_notifications(interaction, user_id)
    user_notifications = @state_store[user_id]
    
    if !user_notifications || user_notifications.empty?
      interaction.reply(content: "You don't have any active notifications to clear.", ephemeral: true)
      return
    end
    
    # Clear each notification
    notification_count = user_notifications.size
    user_notifications.keys.each do |type|
      clear_notification(user_id, type)
    end
    
    interaction.reply(content: "Cleared #{notification_count} notifications.", ephemeral: true)
  end
  
  # Show notification help
  # @param interaction [Object] Discord interaction
  def show_notification_help(interaction)
    message = "**Notification System Help**\n\n" +
              "Commands:\n" +
              "- `/notifications status` - Show your active notifications\n" +
              "- `/notifications clear` - Clear all your notifications\n\n" +
              "Response Keywords:\n" +
              "- `!ready` or `ready` - Confirm match queue or pre-game notifications\n" +
              "- `!active` or `active` - Confirm role retention notifications\n" +
              "- `!cancel` or `cancel` - Cancel any notification\n"
              
    interaction.reply(content: message, ephemeral: true)
  end
  
  # Get the number of active notifications for a user
  # @param user_id [String] Discord user ID
  # @return [Integer] Number of active notifications
  def user_notification_count(user_id)
    user_notifications = @state_store[user_id]
    return 0 unless user_notifications
    user_notifications.size
  end
end
