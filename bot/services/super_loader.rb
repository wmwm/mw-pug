require 'yaml'
require 'pathname'
require 'logger'
require 'json'
require 'ostruct'
require 'securerandom'

# SuperLoader
#
# A utility for executing YAML-driven upgrade steps for the PugBot system.
# This loader handles schema migrations, configuration updates, and other
# automated deployment tasks defined in YAML configuration files.
class SuperLoader
  attr_reader :config_path, :dependencies, :dry_run, :resource_cache, :handlers
  
  # Creates a new SuperLoader instance
  # @param options [Hash] Configuration options
  # @option options [String] :config_path Path to the directory containing loader YAML files
  # @option options [Hash] :dependencies Dependencies injected into the loader
  # @option options [Boolean] :dry_run If true, simulates execution without making actual changes
  def initialize(options = {})
    @config_path = options[:config_path] || File.join(Dir.pwd, 'config')
    @dependencies = options[:dependencies] || {}
    @dry_run = options[:dry_run] || false
    
    # Set up the resource cache
    @resource_cache = {
      channels: {},
      roles: {},
      config_values: {}
    }
    
    # Set up event listeners
    @event_listeners = {
      'upgrade:start' => [],
      'upgrade:complete' => [],
      'upgrade:error' => [],
      'step:start' => [],
      'step:complete' => [],
      'rollback:start' => [],
      'rollback:complete' => []
    }
    
    # Initialize rollback steps
    @rollback_steps = []
    
    # Logger for SuperLoader
    @logger = @dependencies[:logger] || Logger.new(STDOUT)
    
    # Registry of step handlers
    @handlers = {
      'schema_update' => method(:handle_schema_update),
      'data_migration' => method(:handle_data_migration),
      'discord_resources' => method(:handle_discord_resources),
      'config_update' => method(:handle_config_update),
      'command_registry' => method(:handle_command_registry),
      'agent_binding' => method(:handle_agent_binding),
      'database_schema' => method(:handle_database_schema),
      'preprocess_notification' => method(:handle_preprocess_notification),
      'check_expirations' => method(:handle_check_expirations),
      'queue_keep_alive_processing' => method(:handle_queue_keep_alive_processing)
    }
    
    @logger.info('SuperLoader initialized')
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
  
  # Count listeners for an event
  # @param event_name [String] Name of the event
  # @return [Integer] Number of listeners
  def listener_count(event_name)
    return 0 unless @event_listeners.key?(event_name)
    @event_listeners[event_name].size
  end
  
  # Emit an event
  # @param event_name [String] Name of the event
  # @param data [Hash] Data to pass to the event listeners
  def emit(event_name, data = {})
    return unless @event_listeners.key?(event_name)
    @event_listeners[event_name].each { |listener| listener.call(data) }
  end
  
  # Loads and parses a YAML configuration file
  # @param filename [String] The name of the YAML file to load
  # @return [Hash] The parsed YAML configuration
  def load_config(filename)
    begin
      file_path = File.join(@config_path, filename)
      file_content = File.read(file_path)
      config = YAML.safe_load(file_content)
      
      @logger.info("Loaded configuration from #{filename}")
      config
    rescue => error
      @logger.error("Failed to load configuration from #{filename}: #{error.message}")
      raise
    end
  end
  
  # Executes an upgrade sequence from a YAML configuration
  # @param filename [String] The name of the YAML file containing the upgrade sequence
  # @return [Hash] Results of the upgrade
  def execute_upgrade(filename)
    begin
      config = load_config(filename)
      
      @logger.info("Executing upgrade sequence: #{config['description']}")
      emit('upgrade:start', { config: config })
      
      # Sort upgrade steps by execute_order
      ordered_steps = config['upgrade_sequence'].sort_by { |s| s['execute_order'] }
      
      results = []
      requires_restart = false
      
      # Execute each step in order
      ordered_steps.each do |step|
        @logger.info("Executing step #{step['id']}: #{step['name']}")
        emit('step:start', { step: step })
        
        step_result = execute_step(step)
        requires_restart = requires_restart || step['requires_restart']
        
        results << {
          id: step['id'],
          name: step['name'],
          success: step_result[:success],
          details: step_result[:details]
        }
        
        emit('step:complete', { step: step, result: step_result })
        
        # If a step fails, stop the execution
        unless step_result[:success]
          @logger.error("Step #{step['id']} failed: #{step_result[:error]}")
          
          # Attempt rollback if supported
          if step['rollback_supported']
            execute_rollback
          end
          
          emit('upgrade:error', { step: step, error: step_result[:error] })
          raise "Upgrade failed at step #{step['id']}: #{step_result[:error]}"
        end
      end
      
      emit('upgrade:complete', { results: results, requires_restart: requires_restart })
      @logger.info('Upgrade sequence completed successfully')
      
      {
        success: true,
        results: results,
        requires_restart: requires_restart
      }
    rescue => error
      @logger.error("Upgrade failed: #{error.message}")
      {
        success: false,
        error: error.message
      }
    end
  end
  
  # Executes a single upgrade step
  # @param step [Hash] The step configuration
  # @return [Hash] Result of the step execution
  def execute_step(step)
    begin
      results = []
      
      # Execute each sub-step
      step['steps'].each do |sub_step|
        handler = @handlers[sub_step['type']]
        
        unless handler
          raise "Unknown step type: #{sub_step['type']}"
        end
        
        @logger.debug("Executing sub-step: #{sub_step['type']} - #{sub_step['action']}")
        
        # If this is a dry run, don't actually execute the step
        if @dry_run
          @logger.info("[DRY RUN] Would execute #{sub_step['type']}:#{sub_step['action']}")
          results << { success: true, dry_run: true }
          next
        end
        
        result = handler.call(sub_step)
        
        # If the step supports rollback, register a rollback step
        if step['rollback_supported'] && result[:rollback]
          @rollback_steps.unshift(result[:rollback])
        end
        
        results << result
      end
      
      {
        success: true,
        details: results
      }
    rescue => error
      @logger.error("Step execution error: #{error.message}")
      {
        success: false,
        error: error.message
      }
    end
  end
  
  # Executes rollback steps in reverse order
  def execute_rollback
    @logger.warn('Executing rollback steps')
    emit('rollback:start')
    
    @rollback_steps.each do |rollback_step|
      begin
        @logger.debug("Executing rollback: #{rollback_step[:description]}")
        rollback_step[:execute].call
      rescue => error
        @logger.error("Rollback step failed: #{error.message}")
      end
    end
    
    emit('rollback:complete')
    @rollback_steps = []
  end
  
  # Checks if a step type is available
  # @param step_name [String] The type of step to check for
  # @return [Boolean] True if the step type exists
  def has_step?(step_name)
    @handlers.key?(step_name)
  end
  
  # Executes a specific step with parameters
  # @param step_name [String] The type of step to execute
  # @param params [Hash] Parameters for the step
  # @return [Hash] Result of the step execution
  def exec_step(step_name, params = {})
    handler = @handlers[step_name]
    
    unless handler
      raise "Unknown step type: #{step_name}"
    end
    
    handler.call({ 'params' => params })
  end
  
  # Validates if dependencies are available
  # @param required_deps [Array<String>] List of required dependency names
  # @return [Boolean] True if all dependencies are available
  def validate_dependencies(required_deps)
    required_deps.each do |dep|
      unless @dependencies[dep.to_sym]
        @logger.error("Missing required dependency: #{dep}")
        return false
      end
    end
    true
  end
  
  # Resolves template variables in configuration values
  # @param value [String, Object] The template string to resolve
  # @return [String, Object] The resolved value
  def resolve_template_values(value)
    return value unless value.is_a?(String)
    
    value.gsub(/\{([^}]+)\}/) do |match|
      key = $1
      type, id = key.split(':')
      
      case type
      when 'channel'
        @resource_cache[:channels][id] || match
      when 'role'
        @resource_cache[:roles][id] || match
      when 'config'
        @resource_cache[:config_values][id] || match
      else
        match
      end
    end
  end
  
  #==============================
  # Step Handlers
  #==============================
  
  # Handles schema_update steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_schema_update(step)
    unless validate_dependencies(['config_manager'])
      return { success: false, error: 'Missing config_manager dependency' }
    end
    
    config_manager = @dependencies[:config_manager]
    target = step['target']
    action = step['action']
    params = step['params'] || {}
    
    begin
      case action
      when 'transform'
        config_manager.transform_schema(target, params['from_version'], params['to_version'], params['transforms'])
      else
        raise "Unknown action: #{action}"
      end
      
      {
        success: true,
        rollback: {
          description: "Revert schema from #{params['to_version']} to #{params['from_version']}",
          execute: -> {
            config_manager.revert_schema(target, params['to_version'], params['from_version'])
          }
        }
      }
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles data_migration steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_data_migration(step)
    unless validate_dependencies(['database'])
      return { success: false, error: 'Missing database dependency' }
    end
    
    database = @dependencies[:database]
    target = step['target']
    action = step['action']
    params = step['params'] || {}
    
    begin
      case action
      when 'add_field'
        database.add_field(target, params['field_name'], params['default_value'])
      when 'transform_data'
        database.transform_data(target, params['transform_function'])
      else
        raise "Unknown action: #{action}"
      end
      
      {
        success: true,
        rollback: {
          description: "Revert data migration on #{target}",
          execute: -> {
            if action == 'add_field'
              database.remove_field(target, params['field_name'])
            elsif action == 'transform_data' && params['revert_function']
              database.transform_data(target, params['revert_function'])
            end
          }
        }
      }
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles discord_resources steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_discord_resources(step)
    unless validate_dependencies(['discord'])
      return { success: false, error: 'Missing discord dependency' }
    end
    
    discord = @dependencies[:discord]
    target = step['target']
    action = step['action']
    params = step['params'] || {}
    
    begin
      case target
      when 'channels'
        if action == 'ensure_exists'
          created_channels = []
          
          params['channels'].each do |channel_config|
            channel = discord.ensure_channel(channel_config)
            
            if channel_config['store_id_as']
              @resource_cache[:channels][channel_config['store_id_as']] = channel.id
            end
            
            created_channels << {
              name: channel.name,
              id: channel.id,
              store_id_as: channel_config['store_id_as']
            }
          end
          
          return {
            success: true,
            resources: created_channels,
            rollback: {
              description: "Remove created channels",
              execute: -> {
                created_channels.each do |channel|
                  @resource_cache[:channels].delete(channel[:store_id_as]) if channel[:store_id_as]
                  discord.delete_channel(channel[:id])
                end
              }
            }
          }
        end
        
      when 'roles'
        if action == 'ensure_exists'
          created_roles = []
          
          params['roles'].each do |role_config|
            role = discord.ensure_role(role_config)
            
            if role_config['store_id_as']
              @resource_cache[:roles][role_config['store_id_as']] = role.id
            end
            
            created_roles << {
              name: role.name,
              id: role.id,
              store_id_as: role_config['store_id_as']
            }
          end
          
          return {
            success: true,
            resources: created_roles,
            rollback: {
              description: "Remove created roles",
              execute: -> {
                created_roles.each do |role|
                  @resource_cache[:roles].delete(role[:store_id_as]) if role[:store_id_as]
                  discord.delete_role(role[:id])
                end
              }
            }
          }
        end
        
      else
        raise "Unknown target: #{target}"
      end
      
      raise "Unknown action: #{action} for target: #{target}"
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles config_update steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_config_update(step)
    unless validate_dependencies(['config_manager'])
      return { success: false, error: 'Missing config_manager dependency' }
    end
    
    config_manager = @dependencies[:config_manager]
    target = step['target']
    action = step['action']
    params = step['params'] || {}
    
    begin
      old_config = config_manager.get_config(target)
      
      case action
      when 'add_fields'
        resolved_fields = {}
        
        # Resolve template values
        params['fields'].each do |key, value|
          resolved_fields[key] = resolve_template_values(value)
          
          if params['store_as'] && params['store_as'][key]
            @resource_cache[:config_values][params['store_as'][key]] = resolved_fields[key]
          end
        end
        
        config_manager.update_config(target, resolved_fields)
        
      when 'update_fields'
        resolved_updates = {}
        
        # Resolve template values
        params['fields'].each do |key, value|
          resolved_updates[key] = resolve_template_values(value)
        end
        
        config_manager.update_config(target, resolved_updates)
        
      when 'remove_fields'
        config_manager.remove_fields(target, params['fields'])
        
      else
        raise "Unknown action: #{action}"
      end
      
      {
        success: true,
        rollback: {
          description: "Revert config changes to #{target}",
          execute: -> {
            config_manager.set_config(target, old_config)
          }
        }
      }
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles command_registry steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_command_registry(step)
    unless validate_dependencies(['command_registry'])
      return { success: false, error: 'Missing command_registry dependency' }
    end
    
    command_registry = @dependencies[:command_registry]
    action = step['action']
    params = step['params'] || {}
    
    begin
      registered_commands = []
      
      case action
      when 'register'
        params['commands'].each do |command|
          command_registry.register_command(command)
          registered_commands << command['name']
        end
        
      when 'unregister'
        params['commands'].each do |command_name|
          command_registry.unregister_command(command_name)
        end
        
      else
        raise "Unknown action: #{action}"
      end
      
      result = {
        success: true,
        commands: registered_commands
      }
      
      if action == 'register'
        result[:rollback] = {
          description: "Unregister commands",
          execute: -> {
            registered_commands.each do |command_name|
              command_registry.unregister_command(command_name)
            end
          }
        }
      end
      
      result
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles agent_binding steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_agent_binding(step)
    unless validate_dependencies(['agent_manager'])
      return { success: false, error: 'Missing agent_manager dependency' }
    end
    
    agent_manager = @dependencies[:agent_manager]
    target = step['target']
    action = step['action']
    params = step['params'] || {}
    
    begin
      bindings = []
      
      case target
      when 'event_bus'
        if action == 'subscribe'
          params['events'].each do |event|
            agent_manager.subscribe_to_event(
              params['source_agent'], 
              event['event'], 
              event['handler']
            )
            
            bindings << {
              source: params['source_agent'],
              event: event['event'],
              handler: event['handler']
            }
          end
        elsif action == 'unsubscribe'
          params['events'].each do |event|
            agent_manager.unsubscribe_from_event(
              params['source_agent'],
              event['event'],
              event['handler']
            )
          end
        end
        
      when 'api'
        if action == 'expose'
          params['methods'].each do |method|
            agent_manager.expose_method(
              method['name'],
              method['handler']
            )
            
            bindings << {
              method: method['name'],
              handler: method['handler']
            }
          end
        elsif action == 'unexpose'
          params['methods'].each do |method_name|
            agent_manager.unexpose_method(method_name)
          end
        end
        
      else
        raise "Unknown target: #{target}"
      end
      
      rollback = nil
      
      if target == 'event_bus' && action == 'subscribe'
        rollback = {
          description: "Revert agent bindings",
          execute: -> {
            bindings.each do |binding|
              agent_manager.unsubscribe_from_event(
                binding[:source],
                binding[:event],
                binding[:handler]
              )
            end
          }
        }
      elsif target == 'api' && action == 'expose'
        rollback = {
          description: "Revert agent bindings",
          execute: -> {
            bindings.each do |binding|
              agent_manager.unexpose_method(binding[:method])
            end
          }
        }
      end
      
      {
        success: true,
        bindings: bindings,
        rollback: rollback
      }
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles database_schema steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_database_schema(step)
    unless validate_dependencies(['database'])
      return { success: false, error: 'Missing database dependency' }
    end
    
    database = @dependencies[:database]
    action = step['action']
    params = step['params'] || {}
    
    begin
      case action
      when 'ensure_table'
        table_exists = database.table_exists?(params['table_name'])
        
        unless table_exists
          database.create_table(params['table_name'], params['schema'])
        end
        
      when 'add_columns'
        database.add_columns(params['table_name'], params['columns'])
        
      when 'drop_table'
        database.drop_table(params['table_name'])
        
      else
        raise "Unknown action: #{action}"
      end
      
      rollback = nil
      
      if action != 'drop_table'
        rollback = {
          description: "Revert database schema changes",
          execute: -> {
            if action == 'ensure_table' && !table_exists
              database.drop_table(params['table_name'])
            elsif action == 'add_columns'
              database.drop_columns(params['table_name'], params['columns'].map { |c| c['name'] })
            end
          }
        }
      end
      
      {
        success: true,
        rollback: rollback
      }
    rescue => error
      { success: false, error: error.message }
    end
  end
  
  # Handles notification preprocessing steps
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_preprocess_notification(step)
    unless validate_dependencies(['agent_manager'])
      return { success: false, error: 'Missing agent_manager dependency' }
    end
    
    begin
      user_id = step['params']['userId']
      type = step['params']['type']
      context = step['params']['context'] || {}
      
      # Apply any transformations defined in the config
      modified_context = context.dup
      skip_notification = false
      result_value = true
      
      # Get notification tier if available
      notification_tier = 2 # Default to tier 2 (Informational)
      
      # Get NotificationAgent instance if available
      notification_agent = @dependencies[:agent_manager].get_agent('Notification')
      if notification_agent && notification_agent.respond_to?(:get_notification_tier)
        notification_tier = notification_agent.get_notification_tier(type)
      elsif notification_agent && notification_agent.config && 
            notification_agent.config['triggers'] && 
            notification_agent.config['triggers'][type] && 
            notification_agent.config['triggers'][type]['tier'].is_a?(Numeric)
        notification_tier = notification_agent.config['triggers'][type]['tier']
      end
      
      # Get user status if possible
      user_status = 'online' # Default to online
      begin
        if @dependencies[:discord]
          user = @dependencies[:discord].get_user(user_id)
          if user && user.presence
            user_status = user.presence.status
          end
        end
      rescue => err
        @logger.error("Error checking user status: #{err.message}")
      end
      
      # Enhanced preprocessing logic based on notification type and tier
      case type
      when 'match_queue'
        # Tier 0 (Critical) - Check if user is already in an active match
        begin
          if @dependencies[:match_manager]
            user_matches = @dependencies[:match_manager].get_user_active_matches(user_id)
            if user_matches && !user_matches.empty?
              # User is in an active match, skip the notification
              @logger.info("Skipping match_queue notification for #{user_id} - already in active match")
              skip_notification = true
            end
          end
        rescue => err
          @logger.error("Error checking match status: #{err.message}")
        end
        
        # For offline users, update the context to increase visibility
        if user_status == 'offline' || user_status == 'idle'
          modified_context[:urgent] = true
          modified_context[:timeout] = [modified_context[:timeout] || 300, 600].max # Extend timeout for offline users
          @logger.info("Enhanced match_queue notification for #{user_id} - offline/idle status detected")
        end
        
      when 'pre_game'
        # Tier 0 (Critical) - Always process these regardless of status
        # But add more context based on user's status
        if user_status == 'offline'
          modified_context[:urgent] = true
          modified_context[:require_confirmation] = true
          @logger.info("Enhanced pre_game notification for offline user #{user_id}")
        end
        
      when 'role_retention'
        # Tier 1 (Important) - Check user status and activity
        begin
          if @dependencies[:discord]
            user = @dependencies[:discord].get_user(user_id)
            if user && user.presence && user.presence.status == 'dnd'
              # Add additional context about dnd status
              modified_context[:user_status] = 'dnd'
              modified_context[:extension_days] = 3 # Give DND users extra days
              
              @logger.info("Modified role_retention notification for #{user_id} - DND status detected")
            end
          end
          
          # Check user's recent activity if available
          if @dependencies[:player_state_agent]
            last_active = @dependencies[:player_state_agent].get_last_active_time(user_id)
            
            # If user was active in last 72 hours, auto-confirm and skip notification
            if last_active && (Time.now.to_i * 1000 - last_active) < 259200000 # 72 hours in ms
              @logger.info("Auto-confirming role retention for recently active user #{user_id}")
              
              # Emit event for notification agent to handle
              if @dependencies[:agent_manager]
                @dependencies[:agent_manager].emit('role:retention_auto_confirmed', {
                  user_id: user_id,
                  role_name: modified_context['role_name'],
                  reason: 'recent_activity'
                })
                
                skip_notification = true
                result_value = true # Return success
              end
            end
          end
        rescue => err
          @logger.error("Error processing role_retention status: #{err.message}")
        end
        
      when 'match_result', 'announcements', 'tips'
        # For lower priority notifications (Tier 1-2), respect user preferences
        begin
          # Check user preferences if available
          if @dependencies[:player_state_agent] && 
              @dependencies[:player_state_agent].respond_to?(:get_user_notification_preferences)
            prefs = @dependencies[:player_state_agent].get_user_notification_preferences(user_id)
            
            # Skip if user doesn't want this tier
            if prefs && prefs[:max_tier].is_a?(Numeric) && notification_tier > prefs[:max_tier]
              @logger.info("Skipping tier #{notification_tier} notification for #{user_id} based on user preferences")
              skip_notification = true
              result_value = true
            end
            
            # For DND status, skip non-critical notifications
            if user_status == 'dnd' && notification_tier > 0
              @logger.info("Skipping tier #{notification_tier} notification for DND user #{user_id}")
              skip_notification = true
              result_value = true
            end
          end
        rescue => err
          @logger.error("Error checking user preferences: #{err.message}")
        end
      end
      
      # If specific handler functions defined, execute them
      if step['params']['handler']
        handler_fn = @dependencies[step['params']['handler'].to_sym]
        if handler_fn.respond_to?(:call)
          result = handler_fn.call(user_id, type, modified_context)
          
          # Handler can return modified context or indicate to skip notification
          if result
            if result[:skip]
              skip_notification = true
              result_value = result[:result] unless result[:result].nil?
            end
            
            modified_context = result[:context] if result[:context]
          end
        end
      end
      
      # Add metadata to the context
      modified_context[:_meta] = {
        tier: notification_tier,
        user_status: user_status,
        processed_at: Time.now.to_i * 1000
      }
      
      # If notification should be skipped, return early
      if skip_notification
        return { 
          success: true, 
          skip: true,
          result: result_value
        }
      end
      
      {
        success: true,
        context: modified_context
      }
    rescue => error
      @logger.error("Error in preprocess_notification step: #{error.message}")
      { 
        success: true, 
        error: error.message,
        context: step['params']['context'] # Return original context on error
      }
    end
  end
  
  # Handles custom expiration logic for notifications
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_check_expirations(step)
    unless validate_dependencies(['agent_manager'])
      return { success: false, error: 'Missing agent_manager dependency' }
    end
    
    begin
      state_store = step['params']['stateStore']
      handled = false
      
      # If a custom handler is specified, use it first
      if step['params']['handler']
        handler_fn = @dependencies[step['params']['handler'].to_sym]
        if handler_fn.respond_to?(:call)
          result = handler_fn.call(state_store)
          handled = result && result[:handled]
          
          if handled
            return {
              success: true,
              handled: true
            }
          end
        end
      end
      
      # If no custom handler or not handled, implement common expiration strategies
      if !handled && state_store
        now = Time.now.to_i * 1000
        expired_items = []
        extended_items = []
        
        # Get notification agent for tier info
        notification_agent = @dependencies[:agent_manager]&.get_agent('Notification')
        
        # Process notifications with tier-specific logic
        state_store.each do |user_id, notifications|
          notifications.each do |type, data|
            # Skip notifications without expiry
            next if data[:expires_at] == 0
            
            # Calculate expiration details
            time_until_expiry = data[:expires_at] - now
            is_expired = time_until_expiry <= 0
            is_about_to_expire = !is_expired && time_until_expiry <= 30000 # Within 30 seconds
            
            # Get tier from data or lookup
            tier = data[:tier]
            unless tier
              if notification_agent&.respond_to?(:get_notification_tier)
                tier = notification_agent.get_notification_tier(type)
              else
                tier = case type
                       when 'match_queue', 'pre_game' then 0
                       when 'role_retention', 'match_result' then 1
                       else 2
                       end
              end
            end
            
            # Process based on tier and expiration status
            if is_expired || is_about_to_expire
              # Handle based on notification tier and type
              case
              # TIER 0 (CRITICAL) - Special handling for game-critical notifications
              when tier == 0 && (type == 'match_queue' || type == 'pre_game')
                # Check if user is online but missed the notification
                user_status = 'unknown'
                
                begin
                  if @dependencies[:discord]
                    user = @dependencies[:discord].get_user(user_id)
                    if user && user.presence
                      user_status = user.presence.status
                    end
                  end
                rescue => err
                  @logger.error("Error checking user status: #{err.message}")
                end
                
                # For online users, give extra grace period for critical notifications
                if (user_status == 'online' || user_status == 'idle') && is_about_to_expire
                  # Extend expiration by 30 seconds for active users
                  extension_time = 30000 # 30 seconds
                  data[:expires_at] += extension_time
                  
                  # If we have notify service, try to ping them again
                  if type == 'pre_game' && @dependencies[:discord]
                    begin
                      user = @dependencies[:discord].get_user(user_id)
                      if user
                        user.send("⚠️ **REMINDER:** Your match is starting! Please respond within #{(extension_time/1000).ceil} seconds!")
                      end
                    rescue => err
                      @logger.error("Error sending reminder: #{err.message}")
                    end
                  end
                  
                  # Track that we extended this item
                  extended_items << { user_id: user_id, type: type, extension_time: extension_time }
                  @logger.info("Extended #{type} expiration for online user #{user_id} by #{extension_time/1000} seconds")
                  
                  # Don't expire it yet
                  next
                end
                
                # For queue checks, verify if user is still in queue before expiring
                if type == 'match_queue' && @dependencies[:queue_manager]
                  begin
                    is_queued = @dependencies[:queue_manager].is_user_in_queue(
                      user_id, 
                      data[:context][:queue_id]
                    )
                    
                    # If user is no longer in queue, remove the notification
                    if !is_queued
                      @logger.info("Removing match_queue notification for #{user_id} - no longer in queue")
                      expired_items << { user_id: user_id, type: type }
                      next
                    end
                  rescue => err
                    @logger.error("Error checking queue status: #{err.message}")
                  end
                end
                
              # TIER 1 (IMPORTANT) - Handle role retention with activity checking
              when tier == 1 && type == 'role_retention'
                # For role retention, check if user has been active recently
                if @dependencies[:player_state_agent]
                  begin
                    last_active = @dependencies[:player_state_agent].get_last_active_time(user_id)
                    
                    # If user was active in the last 48 hours, auto-confirm
                    activity_threshold = 48 * 60 * 60 * 1000 # 48 hours
                    
                    if last_active && (now - last_active) < activity_threshold
                      @logger.info("Auto-confirming role retention for active user #{user_id}")
                      
                      # Emit event for notification agent to handle
                      if @dependencies[:agent_manager]
                        @dependencies[:agent_manager].emit('role:retention_auto_confirmed', {
                          user_id: user_id,
                          role_name: data[:context][:role_name],
                          reason: 'recent_activity'
                        })
                      end
                      
                      # Mark as handled by removing
                      expired_items << { user_id: user_id, type: type }
                      next
                    end
                  rescue => err
                    @logger.error("Error checking user activity: #{err.message}")
                  end
                end
                
              # TIER 2 (INFORMATIONAL) - Just let them expire normally
              when tier == 2
                # No special handling for informational notifications
                
              # For any other notification types, check if they're actually expired
              else
                if is_expired
                  expired_items << { user_id: user_id, type: type }
                end
              end
            end
          end
        end
        
        # Apply our notification extensions if any
        if !extended_items.empty?
          handled = true
          extended_items.each do |item|
            @logger.info("Extended #{item[:type]} notification for #{item[:user_id]} by #{item[:extension_time]/1000}s")
          end
        end
        
        # Apply any expired item removals
        if !expired_items.empty?
          # Process each expired item
          expired_items.each do |item|
            user_notifications = state_store[item[:user_id]]
            if user_notifications
              # Remove this notification
              user_notifications.delete(item[:type])
              
              # Remove user if no more notifications
              if user_notifications.empty?
                state_store.delete(item[:user_id])
              else
                state_store[item[:user_id]] = user_notifications
              end
            end
          end
          
          # Mark as handled if we processed anything
          handled = true
        end
      end
      
      {
        success: true,
        # Always mark as handled if we found expired items or extended any expirations
        handled: true
      }
    rescue => error
      @logger.error("Error in check_expirations step: #{error.message}")
      { 
        success: true,
        error: error.message,
        handled: false
      }
    end
  end
  
  # Handles queue keep-alive processing with enhanced logic
  # @param step [Hash] Step configuration
  # @return [Hash] Step result
  def handle_queue_keep_alive_processing(step)
    unless validate_dependencies(['agent_manager'])
      return { success: false, error: 'Missing agent_manager dependency' }
    end
    
    begin
      user_id = step['params']['userId']
      context = step['params']['context'] || {}
      processed = false
      
      # If a custom handler is specified, use it first
      if step['params']['handler']
        handler_fn = @dependencies[step['params']['handler'].to_sym]
        if handler_fn.respond_to?(:call)
          result = handler_fn.call(user_id, context)
          if result && result[:processed]
            return {
              success: true,
              processed: true,
              success: result[:success].nil? ? true : result[:success]
            }
          end
        end
      end
      
      # Implement enhanced keep-alive logic with tiered approach
      
      # 1. Check user's current status
      user_status = 'online'
      if @dependencies[:discord]
        begin
          user = @dependencies[:discord].get_user(user_id)
          if user && user.presence
            user_status = user.presence.status
          end
        rescue => err
          @logger.error("Error getting user status: #{err.message}")
        end
      end
      
      # 2. Check if user has queued recently and their activity pattern
      frequent_user = false
      recently_active = false
      queue_abandon_rate = 0
      
      if @dependencies[:database]
        begin
          # Get recent queue history (last 7 days)
          recent_activity = @dependencies[:database].get_user_queue_history(
            user_id, 
            Time.now.to_i * 1000 - (7 * 24 * 60 * 60 * 1000) # Last 7 days
          )
          
          frequent_user = recent_activity && recent_activity[:count] >= 10
          
          # Check if user has been active in the last hour
          if @dependencies[:player_state_agent] && 
              @dependencies[:player_state_agent].respond_to?(:get_last_active_time)
            last_active = @dependencies[:player_state_agent].get_last_active_time(user_id)
            recently_active = last_active && (Time.now.to_i * 1000 - last_active < 3600000) # Active in last hour
          end
          
          # Check if user has a history of abandoning queues
          if recent_activity && recent_activity[:queued] && recent_activity[:abandoned]
            queue_abandon_rate = recent_activity[:abandoned].to_f / recent_activity[:queued].to_f
          end
        rescue => err
          @logger.error("Error checking user queue history: #{err.message}")
        end
      end
      
      # 3. Determine if we should modify the keep-alive behavior based on user profile
      match_name = context[:match_name]
      queue_id = context[:queue_id]
      
      # Create a comprehensive user profile for keep-alive decision
      user_profile = {
        status: user_status,
        frequent_user: frequent_user,
        recently_active: recently_active,
        queue_abandon_rate: queue_abandon_rate
      }
      
      # Smart handling based on user profile
      case
      # Case 1: Active, frequent user with good history - auto-confirm
      when (user_status == 'online' && frequent_user && queue_abandon_rate < 0.1)
        @logger.info("Auto-confirming queue keep-alive for reliable frequent user #{user_id}")
        
        # Emit auto-confirm event
        if @dependencies[:agent_manager]
          @dependencies[:agent_manager].emit('queue:keep_alive_auto_confirmed', {
            user_id: user_id,
            queue_id: queue_id,
            match_name: match_name,
            reason: 'reliable_frequent_user',
            user_profile: user_profile
          })
        end
        
        processed = true
        
      # Case 2: Recently active users - extend timeout 
      when (recently_active && user_status != 'offline')
        @logger.info("Extending keep-alive timeout for recently active user #{user_id}")
        
        # Custom handling for users who were just active
        if @dependencies[:agent_manager]
          # Return context with extended timeout
          notification_agent = @dependencies[:agent_manager].get_agent('Notification')
          if notification_agent
            user_notifications = notification_agent.state_store[user_id] || {}
            
            # If there's an existing match_queue notification, extend it
            if user_notifications['match_queue'] && 
                user_notifications['match_queue'][:expires_at] > 0
              # Extend by 50%
              current_expiry = user_notifications['match_queue'][:expires_at]
              new_expiry = [
                current_expiry,
                Time.now.to_i * 1000 + ((current_expiry - Time.now.to_i * 1000) * 1.5)
              ].max
              
              user_notifications['match_queue'][:expires_at] = new_expiry
              notification_agent.state_store[user_id] = user_notifications
              
              @logger.info("Extended match_queue expiration for #{user_id} to #{Time.at(new_expiry/1000).iso8601}")
              processed = true
            end
          end
        end
        
      # Case 3: Offline users with high abandon rate - no special processing
      when (user_status == 'offline' && queue_abandon_rate > 0.5)
        @logger.info("Standard processing for offline user #{user_id} with high abandon rate")
        
      # Case 4: DND users - check if match is about to start
      when (user_status == 'dnd')
        # Check if match is about to start
        begin
          if @dependencies[:queue_manager] && 
              @dependencies[:queue_manager].respond_to?(:get_queue_status)
            queue_status = @dependencies[:queue_manager].get_queue_status(queue_id)
            
            # If queue is almost full (>80%), try to notify DND user
            if queue_status && queue_status[:percentage] >= 80
              @logger.info("Special DND handling for user #{user_id} - match almost ready")
              
              # Send a special DND alert via agentManager
              if @dependencies[:agent_manager]
                @dependencies[:agent_manager].emit('queue:dnd_alert', {
                  user_id: user_id,
                  queue_id: queue_id,
                  match_name: match_name,
                  queue_status: queue_status
                })
              end
              
              processed = true
            end
          end
        rescue => err
          @logger.error("Error checking queue status: #{err.message}")
        end
      end
      
      {
        success: true,
        processed: processed
      }
    rescue => error
      @logger.error("Error in queue_keep_alive_processing step: #{error.message}")
      { 
        success: true,
        error: error.message,
        processed: false
      }
    end
  end
end
