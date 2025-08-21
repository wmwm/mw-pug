require 'json'
require 'time'
require 'logger'
require 'aws-sdk-cloudwatch'

class TelemetryService
  attr_reader :logger
  
  # Initialize telemetry service with optional AWS CloudWatch integration
  def initialize(log_file: 'logs/telemetry.log', aws_enabled: ENV['TELEMETRY_CLOUDWATCH_ENABLED'] == 'true')
    # Create logs directory if it doesn't exist
    FileUtils.mkdir_p('logs') unless File.directory?('logs')
    
    @logger = Logger.new(log_file)
    @logger.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime.iso8601} [#{severity}] #{msg}\n"
    end
    
    @aws_enabled = aws_enabled
    if @aws_enabled
      @cloudwatch = Aws::CloudWatch::Client.new(
        region: ENV['AWS_REGION'] || 'ap-southeast-2'
      )
    end
  end
  
  # Record server health check event
  def record_health_check(server_id, instance_id, status, response_time_ms, metrics = {})
    event = {
      event_type: 'server_health_check',
      timestamp: Time.now.iso8601,
      server_id: server_id,
      instance_id: instance_id,
      status: status,
      response_time_ms: response_time_ms,
      metrics: metrics
    }
    
    log_event(event)
    send_to_cloudwatch('ServerHealthCheck', metrics.merge(
      response_time: response_time_ms,
      status_code: status == 'healthy' ? 1 : 0
    )) if @aws_enabled
  end
  
  # Record server operation event (start, stop, recovery)
  def record_operation(operation, instance_id, result, duration_ms, details = {})
    event = {
      event_type: 'server_operation',
      timestamp: Time.now.iso8601,
      operation: operation,
      instance_id: instance_id,
      success: result == :success,
      duration_ms: duration_ms,
      details: details
    }
    
    log_event(event)
    send_to_cloudwatch('ServerOperation', {
      operation_type: operation,
      success: result == :success ? 1 : 0,
      duration: duration_ms
    }) if @aws_enabled
  end
  
  # Record server state change
  def record_state_change(instance_id, previous_state, new_state, triggered_by = 'system')
    event = {
      event_type: 'server_state_change',
      timestamp: Time.now.iso8601,
      instance_id: instance_id,
      previous_state: previous_state,
      new_state: new_state,
      triggered_by: triggered_by
    }
    
    log_event(event)
    send_to_cloudwatch('ServerStateChange', {
      state_transition: "#{previous_state}_to_#{new_state}",
      is_user_triggered: triggered_by == 'user' ? 1 : 0
    }) if @aws_enabled
  end
  
  # Record rollback event
  def record_rollback(instance_id, operation, reason, success = true)
    event = {
      event_type: 'server_rollback',
      timestamp: Time.now.iso8601,
      instance_id: instance_id,
      failed_operation: operation,
      reason: reason,
      success: success
    }
    
    log_event(event)
    send_to_cloudwatch('ServerRollback', {
      rollback_operation: operation,
      rollback_success: success ? 1 : 0
    }) if @aws_enabled
  end
  
  # Export telemetry data for a given timeframe
  def export_telemetry(start_time = nil, end_time = nil, event_types = nil)
    # Default to last 24 hours if not specified
    start_time ||= Time.now - (24 * 60 * 60)
    end_time ||= Time.now
    
    events = read_log_events(start_time, end_time, event_types)
    
    {
      timeframe: {
        start: start_time.iso8601,
        end: end_time.iso8601
      },
      total_events: events.size,
      events: events
    }
  end
  
  private
  
  def log_event(event)
    @logger.info(event.to_json)
  end
  
  # Parse log file and extract events within timeframe
  def read_log_events(start_time, end_time, event_types = nil)
    events = []
    
    begin
      File.foreach(@logger.instance_variable_get(:@logdev).filename) do |line|
        # Skip lines that don't look like our JSON events
        next unless line.include?('"event_type":')
        
        begin
          # Extract timestamp and parse JSON
          timestamp_match = line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2})/)
          next unless timestamp_match
          
          # Check if timestamp is within our range
          timestamp = Time.parse(timestamp_match[1])
          next if timestamp < start_time || timestamp > end_time
          
          # Parse the JSON part
          json_part = line[timestamp_match[0].length..-1].strip
          json_part.sub!(/^\[\w+\]\s+/, '') # Remove severity level
          event = JSON.parse(json_part)
          
          # Filter by event type if specified
          if event_types.nil? || event_types.include?(event['event_type'])
            events << event
          end
        rescue JSON::ParserError => e
          # Skip lines that don't parse as valid JSON
        end
      end
    rescue Errno::ENOENT
      # Log file doesn't exist yet
    end
    
    events
  end
  
  # Send metrics to CloudWatch
  def send_to_cloudwatch(metric_namespace, metrics)
    return unless @aws_enabled
    
    begin
      metric_data = metrics.map do |name, value|
        {
          metric_name: name.to_s,
          value: value.to_f,
          unit: name.to_s.include?('time') || name.to_s.include?('duration') ? 'Milliseconds' : 'Count',
          timestamp: Time.now
        }
      end
      
      @cloudwatch.put_metric_data(
        namespace: "PUGBot/#{metric_namespace}",
        metric_data: metric_data
      )
    rescue => e
      @logger.error("CloudWatch error: #{e.message}")
    end
  end
end
