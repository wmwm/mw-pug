require 'aws-sdk-ec2'
require 'aws-sdk-cloudwatch'
require 'benchmark'
require_relative '../models/server'
require_relative 'telemetry_service'
require_relative 'health_check_service'

class AwsService
  RETRY_ATTEMPTS = 3
  RETRY_DELAY = 2 # seconds
  STATE_CHECK_RETRIES = 10
  STATE_CHECK_DELAY = 5 # seconds
  ROLLBACK_WAIT_TIME = 30 # seconds for cleanup before rollback
  
  attr_reader :telemetry, :health_check
  
  # Initialize AWS EC2 client and resource with flexible region
  def initialize(region: ENV['AWS_REGION'] || 'ap-southeast-2', telemetry_service: nil, health_check_service: nil)
    begin
      if ENV['AWS_ACCESS_KEY_ID'] && ENV['AWS_SECRET_ACCESS_KEY']
        @ec2 = Aws::EC2::Client.new(region: region)
        @resource = Aws::EC2::Resource.new(client: @ec2)
        @aws_available = true
      else
        puts "AWS credentials not found. AWS features will be disabled."
        @aws_available = false
      end
      
      @region = region
      
      # Initialize telemetry and health check services
      @telemetry = telemetry_service || TelemetryService.new
      @health_check = health_check_service || HealthCheckService.new(@telemetry)
      
      # Start background health checks only if AWS is available
      if @aws_available
        health_check_interval = ENV['HEALTH_CHECK_INTERVAL']&.to_i || 60
        @health_check.start_background_checks(health_check_interval) if health_check_interval > 0
      end
    rescue => e
      puts "Error initializing AWS services: #{e.message}"
      @aws_available = false
    end
  end

  require 'yaml'

  # Deploy a new EC2 server instance for FortressOne with enhanced error handling
  # Options can include region, map_name, hostname, instance_type, tags
  def deploy_server(region: 'Sydney', map_name: 'dm4', hostname: 'Pug Fortress', instance_type: ENV['AWS_INSTANCE_TYPE'] || 't2.micro', extra_tags: {})
    operation_start = Time.now
    instance_id = nil
    
    # Check if AWS is available
    unless @aws_available
      return {
        success: false,
        error: 'AWS services are not available. Check your AWS credentials.'
      }
    end
    
    begin
      user_data_script = File.read('aws/user_data.sh')

      s3_bucket = ENV['S3_MAP_BUCKET'] || 'your-default-s3-bucket'
      user_data_script.gsub!('__S3_BUCKET_PLACEHOLDER__', s3_bucket)
      user_data_script.gsub!('__MAP_NAME_PLACEHOLDER__', map_name)
      user_data_script.gsub!('__HOSTNAME_PLACEHOLDER__', hostname)

      # Load default AMI ID from config if ENV not set
      ami_id = ENV['AWS_AMI_ID']
      if ami_id.nil? || ami_id.strip.empty?
        config_path = File.expand_path('../../../config/server_infrastructure.yaml', __FILE__)
        if File.exist?(config_path)
          config = YAML.load_file(config_path)
          ami_id = config['default_ami_id'] if config && config['default_ami_id']
        end
      end

      if ami_id.nil? || ami_id.strip.empty?
        duration_ms = ((Time.now - operation_start) * 1000).to_i
        @telemetry.record_operation('deploy_server', 'none', :failure, duration_ms, 
                                   { error: 'AMI ID missing' })
        
        return {
          success: false,
          error: 'AWS AMI ID is not set. Please set AWS_AMI_ID env variable or default_ami_id in config/server_infrastructure.yaml.'
        }
      end

      # Build tags for the instance
      tags = [
        { key: 'Name', value: "FortressOne-#{Time.now.to_i}" },
        { key: 'Project', value: 'PUGBot' },
        { key: 'Region', value: region },
        { key: 'ManagedBy', value: 'PUGBot-Enhanced' }
      ]
      extra_tags.each { |k, v| tags << { key: k.to_s, value: v.to_s } }

      # Use retry mechanism with exponential backoff
      instance = nil
      attempt_deploy_with_retry(RETRY_ATTEMPTS) do
        instance = @resource.create_instances({
          image_id: ami_id,
          min_count: 1,
          max_count: 1,
          instance_type: instance_type,
          key_name: ENV['AWS_KEY_PAIR_NAME'],
          security_group_ids: [ENV['AWS_SECURITY_GROUP_ID']],
          user_data: Base64.encode64(user_data_script),
          tag_specifications: [{
            resource_type: 'instance',
            tags: tags
          }]
        }).first
      end
      
      instance_id = instance.id

      # Create server record in DB
      server = Server.create(
        aws_instance_id: instance.id,
        region: region,
        status: 'launching',
        launched_at: Time.now
      )

      # Wait for instance to be running with enhanced state validation
      wait_result = wait_for_instance_state(instance, 'running', 300) # 5 minute timeout
      
      unless wait_result[:success]
        duration_ms = ((Time.now - operation_start) * 1000).to_i
        @telemetry.record_operation('deploy_server', instance.id, :failure, duration_ms, 
                                  { error: wait_result[:error], stage: 'state_wait' })
        
        # Auto-rollback on failed start
        rollback_result = rollback_failed_operation(instance.id, 'deploy_server', wait_result[:error])
        
        # Combine the original error with rollback information
        return {
          success: false,
          error: "Instance failed to reach 'running' state: #{wait_result[:error]}",
          rollback: rollback_result
        }
      end
      
      # Reload instance data to get public IP
      instance.load

      # Update server record
      server.update(
        status: instance.state.name,
        public_ip: instance.public_ip_address
      )
      
      # Record successful operation telemetry
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('deploy_server', instance.id, :success, duration_ms, 
                                { region: region, map: map_name })
      
      # Schedule initial health check
      Thread.new do
        sleep 30 # Give the server some time to initialize
        @health_check.check_server_health(server)
      end

      {
        success: true,
        instance_id: instance.id,
        server_id: server.id,
        region: region,
        map: map_name,
        status: instance.state.name,
        public_ip: instance.public_ip_address # Return public IP
      }
    rescue Aws::EC2::Errors::ServiceError => e
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('deploy_server', instance_id || 'none', :failure, duration_ms, 
                                { error: "AWS Service Error: #{e.message}" })
      
      # Auto-rollback if we got an instance ID
      rollback_info = {}
      if instance_id
        rollback_info = rollback_failed_operation(instance_id, 'deploy_server', e.message)
      end
      
      {
        success: false,
        error: "AWS Service Error: #{e.message}",
        rollback: rollback_info
      }
    rescue => e
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('deploy_server', instance_id || 'none', :failure, duration_ms, 
                                { error: "General Error: #{e.message}" })
      
      # Auto-rollback if we got an instance ID
      rollback_info = {}
      if instance_id
        rollback_info = rollback_failed_operation(instance_id, 'deploy_server', e.message)
      end
      
      {
        success: false,
        error: "General Error: #{e.message}",
        rollback: rollback_info
      }
    end
  end
  
  def get_server_status(aws_instance_id)
    operation_start = Time.now
    
    server = Server.find(aws_instance_id: aws_instance_id)
    unless server
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('get_server_status', aws_instance_id, :failure, duration_ms, 
                                { error: 'Server not found' })
      return { success: false, error: 'Server not found' }
    end
    
    begin
      # Get instance from AWS
      instance = @resource.instance(server.aws_instance_id)
      instance.load
      
      # Get health check information
      health_result = @health_check.check_server_health(server)
      
      # Update server status in database
      server.update(
        status: instance.state.name,
        public_ip: instance.public_ip_address
      )
      
      # Calculate duration and record telemetry
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('get_server_status', aws_instance_id, :success, duration_ms, 
                                { status: instance.state.name })
      
      # Enhanced response with health information
      {
        success: true,
        server_id: server.id,
        aws_instance_id: server.aws_instance_id,
        status: instance.state.name,
        public_ip: instance.public_ip_address,
        region: server.region,
        uptime: server.uptime,
        uptime_formatted: server.uptime_formatted,
        player_count: server.player_count,
        health: {
          status: health_result[:status],
          response_time_ms: health_result[:response_time_ms],
          last_checked: Time.now.iso8601
        }
      }
    rescue => e
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('get_server_status', aws_instance_id, :failure, duration_ms, 
                                { error: e.message })
      { success: false, error: e.message }
    end
  end
  
  def terminate_server(aws_instance_id)
    operation_start = Time.now
    
    server = Server.find(aws_instance_id: aws_instance_id)
    unless server
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('terminate_server', aws_instance_id, :failure, duration_ms, 
                                { error: 'Server not found' })
      return { success: false, error: 'Server not found' }
    end
    
    begin
      instance = @resource.instance(server.aws_instance_id)
      instance.terminate
      
      # Update server status and record state change
      prev_status = server.status
      server.update(status: 'terminating')
      @telemetry.record_state_change(
        server.aws_instance_id,
        prev_status,
        'terminating',
        'user'
      )
      
      # Wait for instance to start terminating
      wait_result = wait_for_instance_state(instance, 'shutting-down', 60)
      
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      
      if wait_result[:success]
        @telemetry.record_operation('terminate_server', aws_instance_id, :success, duration_ms)
        { success: true, message: 'Server termination initiated' }
      else
        @telemetry.record_operation('terminate_server', aws_instance_id, :failure, duration_ms, 
                                  { error: wait_result[:error], stage: 'state_wait' })
        
        # Auto-rollback by trying to recover the instance if possible
        rollback_result = rollback_failed_operation(aws_instance_id, 'terminate_server', wait_result[:error])
        
        {
          success: false,
          error: "Failed to terminate server: #{wait_result[:error]}",
          rollback: rollback_result
        }
      end
    rescue => e
      duration_ms = ((Time.now - operation_start) * 1000).to_i
      @telemetry.record_operation('terminate_server', aws_instance_id, :failure, duration_ms, 
                                { error: e.message })
      { success: false, error: e.message }
    end
  end
  
  def terminate_all_servers
    operation_start = Time.now
    
    # Find all FortressOne instances
    instances = @ec2.describe_instances({
      filters: [
        { name: 'tag:Project', values: ['PUGBot'] },
        { name: 'instance-state-name', values: ['running', 'pending'] }
      ]
    })
    
    instance_ids = []
    instances.reservations.each do |reservation|
      reservation.instances.each do |instance|
        instance_ids << instance.instance_id
      end
    end
    
    results = { success: true, terminated_count: 0, instance_ids: [], failures: [] }
    
    unless instance_ids.empty?
      # Terminate instances in batches for better reliability
      instance_ids.each_slice(10) do |batch|
        begin
          @ec2.terminate_instances(instance_ids: batch)
          results[:terminated_count] += batch.size
          results[:instance_ids].concat(batch)
          
          # Update database records and telemetry
          Server.where(aws_instance_id: batch).each do |server|
            prev_status = server.status
            server.update(status: 'terminating')
            
            @telemetry.record_state_change(
              server.aws_instance_id,
              prev_status,
              'terminating',
              'bulk_operation'
            )
          end
        rescue => e
          results[:success] = false
          results[:failures] << {
            instance_ids: batch,
            error: e.message
          }
        end
      end
    end
    
    duration_ms = ((Time.now - operation_start) * 1000).to_i
    @telemetry.record_operation('terminate_all_servers', 'multiple', 
                              results[:success] ? :success : :partial_success, 
                              duration_ms, 
                              { count: results[:terminated_count], 
                                failed_count: results[:failures].size })
    
    results
  end
  
  def list_active_servers
    operation_start = Time.now
    
    servers = Server.where(status: ['launching', 'pending', 'running']).all
    
    results = servers.map do |server|
      status_info = get_server_status(server.aws_instance_id)
      status_info[:success] ? status_info : nil
    end.compact
    
    duration_ms = ((Time.now - operation_start) * 1000).to_i
    @telemetry.record_operation('list_active_servers', 'multiple', :success, duration_ms, 
                              { count: results.size })
    
    results
  end
  
  # Self-healing: Check and repair unhealthy instances
  def perform_self_healing(aws_instance_id = nil)
    if aws_instance_id
      # Heal specific instance
      heal_server(aws_instance_id)
    else
      # Heal all instances that need it
      active_servers = Server.where(status: ['launching', 'pending', 'running']).all
      
      healing_results = []
      active_servers.each do |server|
        healing_results << heal_server(server.aws_instance_id)
      end
      
      return {
        success: true,
        servers_checked: active_servers.size,
        servers_healed: healing_results.count { |r| r[:healing_performed] },
        healing_results: healing_results
      }
    end
  end
  
  # Export telemetry data
  def export_telemetry(start_time = nil, end_time = nil, event_types = nil)
    @telemetry.export_telemetry(start_time, end_time, event_types)
  end
  
  private
  
  # Try to heal a specific server if needed
  def heal_server(aws_instance_id)
    server = Server.find(aws_instance_id: aws_instance_id)
    return { success: false, error: 'Server not found' } unless server
    
    begin
      # Get instance from AWS
      instance = @resource.instance(server.aws_instance_id)
      instance.load
      aws_state = instance.state.name
      
      # Get health check information
      health_result = @health_check.check_server_health(server)
      
      healing_action = nil
      healing_reason = nil
      
      # Check for state inconsistencies
      if aws_state == 'running' && server.status != 'running'
        # Database inconsistency - AWS says running but our DB doesn't
        server.update(status: 'running')
        healing_action = 'status_correction'
        healing_reason = "Corrected status from #{server.status} to running (AWS source of truth)"
      elsif aws_state != 'running' && server.status == 'running'
        # Another inconsistency - DB says running but AWS doesn't
        server.update(status: aws_state)
        healing_action = 'status_correction'
        healing_reason = "Corrected status from running to #{aws_state} (AWS source of truth)"
      end
      
      # Handle health check issues
      if aws_state == 'running' && ['unreachable', 'timeout', 'error'].include?(health_result[:status])
        # Server is running but health check failing - attempt reboot if persistent
        
        # Check if we've had multiple failures
        consecutive_failures = @health_check.instance_variable_get(:@checks_in_progress)
                              &.dig(server.id, :failures) || 0
        
        if consecutive_failures >= 3
          # Try to reboot the instance
          instance.reboot
          
          healing_action = 'reboot'
          healing_reason = "Rebooted unresponsive instance (#{consecutive_failures} consecutive health check failures)"
          
          @telemetry.record_operation('self_healing', aws_instance_id, :success, 0, 
                                     { action: 'reboot', reason: healing_reason })
        end
      end
      
      # Return healing results
      {
        success: true,
        instance_id: aws_instance_id,
        aws_state: aws_state,
        db_state: server.status,
        health_status: health_result[:status],
        healing_performed: !healing_action.nil?,
        healing_action: healing_action,
        healing_reason: healing_reason
      }
    rescue => e
      {
        success: false,
        instance_id: aws_instance_id,
        error: e.message
      }
    end
  end
  
  # Rollback a failed operation
  def rollback_failed_operation(instance_id, operation, reason)
    begin
      @telemetry.record_rollback(instance_id, operation, reason, nil) # nil = pending
      
      case operation
      when 'deploy_server'
        # For failed deployment, terminate the instance
        sleep ROLLBACK_WAIT_TIME # Wait a bit before termination to allow for potential recovery
        
        instance = @resource.instance(instance_id)
        instance.terminate
        
        # Update database if server record exists
        server = Server.find(aws_instance_id: instance_id)
        server.update(status: 'failed_rollback') if server
        
        @telemetry.record_rollback(instance_id, operation, reason, true)
        return { action: 'terminated', success: true }
        
      when 'terminate_server'
        # For failed termination, try to force stop the instance
        instance = @resource.instance(instance_id)
        
        # Try force stopping first if instance is still running
        if ['running', 'pending'].include?(instance.state.name)
          instance.stop(force: true)
          wait_for_instance_state(instance, 'stopped', 60)
        end
        
        # Then try termination again
        instance.terminate
        
        @telemetry.record_rollback(instance_id, operation, reason, true)
        return { action: 'force_terminated', success: true }
      end
      
      # Default fallback for unknown operations
      @telemetry.record_rollback(instance_id, operation, reason, false)
      return { action: 'none', success: false, reason: 'Unknown operation type' }
      
    rescue => e
      @telemetry.record_rollback(instance_id, operation, reason, false)
      return { action: 'failed', success: false, error: e.message }
    end
  end

  # Execute a block with retry logic
  def attempt_deploy_with_retry(max_attempts)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue Aws::EC2::Errors::ServiceError => e
      if attempts < max_attempts
        sleep(RETRY_DELAY * attempts) # Exponential backoff
        retry
      else
        raise
      end
    end
  end
  
  # Enhanced instance state waiting with validation
  def wait_for_instance_state(instance, target_state, timeout_seconds)
    start_time = Time.now
    retries = 0
    
    loop do
      begin
        # Reload instance data
        instance.load
        current_state = instance.state.name
        
        # Check if we've reached the target state
        return { success: true } if current_state == target_state
        
        # Check for terminal states that aren't our target
        terminal_states = ['terminated', 'stopped']
        if terminal_states.include?(current_state) && current_state != target_state
          return { 
            success: false, 
            error: "Instance reached terminal state '#{current_state}' instead of '#{target_state}'" 
          }
        end
        
        # Check if we've timed out
        elapsed = Time.now - start_time
        if elapsed > timeout_seconds
          return { 
            success: false, 
            error: "Timed out after #{timeout_seconds}s waiting for state '#{target_state}', current state: '#{current_state}'" 
          }
        end
        
        # Wait before checking again
        sleep [STATE_CHECK_DELAY, (timeout_seconds - elapsed)].min
        
      rescue => e
        retries += 1
        
        if retries >= STATE_CHECK_RETRIES
          return { success: false, error: "Failed to check instance state: #{e.message}" }
        end
        
        sleep STATE_CHECK_DELAY
      end
    end
  end
end
