require 'net/http'
require 'uri'
require 'json'
require 'timeout'
require_relative 'telemetry_service'
require_relative '../models/server'

class HealthCheckService
  HEALTH_CHECK_PORT = 28000
  HEALTH_CHECK_PATH = '/status'
  DEFAULT_TIMEOUT = 5 # seconds
  DEFAULT_INTERVAL = 60 # seconds
  
  attr_reader :telemetry
  
  def initialize(telemetry_service = nil)
    @telemetry = telemetry_service || TelemetryService.new
    @checks_in_progress = {}
  end
  
  # Check health of a specific server instance
  def check_server_health(server, timeout_seconds = DEFAULT_TIMEOUT)
    return { status: 'unknown', error: 'Server not found' } unless server
    
    # Skip health check if IP is not available
    unless server.public_ip
      return { status: 'unknown', error: 'Server IP not available' }
    end
    
    start_time = Time.now
    uri = URI("http://#{server.public_ip}:#{HEALTH_CHECK_PORT}#{HEALTH_CHECK_PATH}")
    
    begin
      Timeout.timeout(timeout_seconds) do
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          # Try to parse JSON response
          begin
            data = JSON.parse(response.body)
            response_time = ((Time.now - start_time) * 1000).to_i # ms
            
            result = { 
              status: 'healthy', 
              response_time_ms: response_time,
              data: data 
            }
            
            # Update server player count if available
            if data['player_count']
              server.update_player_count(data['player_count'])
            end
            
            # Record telemetry
            @telemetry.record_health_check(
              server.id, 
              server.aws_instance_id, 
              'healthy', 
              response_time,
              data
            )
            
            return result
          rescue JSON::ParserError
            # Non-JSON response but server is up
            response_time = ((Time.now - start_time) * 1000).to_i
            
            @telemetry.record_health_check(
              server.id, 
              server.aws_instance_id, 
              'responding', 
              response_time,
              { raw_size: response.body.size }
            )
            
            return {
              status: 'responding',
              response_time_ms: response_time,
              error: 'Invalid JSON response'
            }
          end
        else
          # Server responded but with an error
          response_time = ((Time.now - start_time) * 1000).to_i
          
          @telemetry.record_health_check(
            server.id, 
            server.aws_instance_id, 
            'error', 
            response_time,
            { http_code: response.code }
          )
          
          return {
            status: 'error',
            response_time_ms: response_time,
            error: "HTTP Error: #{response.code}"
          }
        end
      end
    rescue Timeout::Error
      response_time = ((Time.now - start_time) * 1000).to_i
      
      @telemetry.record_health_check(
        server.id, 
        server.aws_instance_id, 
        'timeout', 
        response_time
      )
      
      return {
        status: 'timeout',
        response_time_ms: response_time,
        error: 'Connection timed out'
      }
    rescue => e
      response_time = ((Time.now - start_time) * 1000).to_i
      
      @telemetry.record_health_check(
        server.id, 
        server.aws_instance_id, 
        'unreachable', 
        response_time,
        { error: e.message }
      )
      
      return {
        status: 'unreachable',
        response_time_ms: response_time,
        error: e.message
      }
    end
  end
  
  # Start health checks for all active servers
  def start_background_checks(interval = DEFAULT_INTERVAL)
    @check_thread = Thread.new do
      loop do
        check_all_servers
        sleep interval
      end
    end
  end
  
  # Stop background health checks
  def stop_background_checks
    @check_thread&.exit
    @check_thread = nil
  end
  
  # Check all active servers
  def check_all_servers
    Server.active.each do |server|
      # Skip if recent check already performed
      next if @checks_in_progress[server.id] && 
              @checks_in_progress[server.id][:last_check] > Time.now - 30
      
      @checks_in_progress[server.id] = { last_check: Time.now }
      
      # Run check in a separate thread
      Thread.new do
        begin
          result = check_server_health(server)
          @checks_in_progress[server.id][:last_result] = result
          
          # Update server status based on health check
          update_server_status(server, result)
        ensure
          # Ensure we don't leave hanging references
          @checks_in_progress.delete(server.id) if @checks_in_progress[server.id]
        end
      end
    end
  end
  
  private
  
  # Update server status based on health check results
  def update_server_status(server, result)
    case result[:status]
    when 'healthy', 'responding'
      # Server is responding, ensure status is updated if needed
      if server.status != 'running'
        server.update(status: 'running')
        @telemetry.record_state_change(
          server.aws_instance_id, 
          server.status, 
          'running', 
          'health_check'
        )
      end
    when 'unreachable', 'timeout'
      # Only mark as offline if multiple consecutive failures
      consecutive_failures = (@checks_in_progress[server.id][:failures] || 0) + 1
      @checks_in_progress[server.id][:failures] = consecutive_failures
      
      if consecutive_failures >= 3 && server.status == 'running'
        server.mark_offline
        @telemetry.record_state_change(
          server.aws_instance_id, 
          'running', 
          'stopped', 
          'health_check'
        )
      end
    end
  end
end
