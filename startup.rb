#!/usr/bin/env ruby

require 'fileutils'
require 'logger'

# Create logger
log_dir = File.expand_path('../logs', __FILE__)
FileUtils.mkdir_p(log_dir)
logger = Logger.new(File.join(log_dir, 'startup.log'))

# Load environment
begin
  require 'dotenv/load'
  logger.info "Environment loaded"
rescue => e
  logger.error "Failed to load environment: #{e.message}"
  exit 1
end

# Initialize database if needed
begin
  require_relative 'bot/config/database'
  require 'sequel/extensions/migration'
  
  # Check if migrations need to be run
  migrations_path = File.expand_path('bot/db/migrations', __FILE__)
  if Dir.exist?(migrations_path)
    logger.info "Running database migrations..."
    Sequel::Migrator.run(DB, migrations_path)
    logger.info "Migrations complete"
  end
rescue => e
  logger.error "Database setup failed: #{e.message}"
  exit 1
end

# Start processes based on arguments
case ARGV[0]&.downcase
when 'bot', nil
  # Start main bot
  logger.info "Starting PugBot..."
  begin
    require_relative 'bot/pugbot_new'
    
    # Initialize telemetry service
    require_relative 'bot/services/telemetry_service'
    require_relative 'bot/services/health_check_service'
    
    bot = PugBot.new
    bot.start
  rescue => e
    logger.error "Bot startup failed: #{e.message}"
    logger.error e.backtrace.join("\n")
    exit 1
  end
  
when 'dashboard'
  # Start telemetry dashboard
  logger.info "Starting Telemetry Dashboard..."
  begin
    require_relative 'dashboard/telemetry_dashboard'
    TelemetryDashboard.run!
  rescue => e
    logger.error "Dashboard startup failed: #{e.message}"
    logger.error e.backtrace.join("\n")
    exit 1
  end
  
when 'health'
  # Run health check service standalone
  logger.info "Starting Health Check Service..."
  begin
    require_relative 'bot/services/telemetry_service'
    require_relative 'bot/services/health_check_service'
    require_relative 'bot/services/aws_service'
    
    telemetry = TelemetryService.new
    health = HealthCheckService.new(telemetry)
    aws = AwsService.new(telemetry_service: telemetry, health_check_service: health)
    
    # Run initial health checks
    logger.info "Running initial health checks..."
    result = aws.perform_self_healing
    logger.info "Checked #{result[:servers_checked]} servers, healed #{result[:servers_healed]} servers"
    
    # Start background health check loop
    interval = ENV['HEALTH_CHECK_INTERVAL']&.to_i || 60
    logger.info "Starting background health checks (interval: #{interval}s)..."
    health.start_background_checks(interval)
    
    # Keep process alive
    loop do
      sleep 60
      logger.info "Health check service running..."
    end
  rescue => e
    logger.error "Health service startup failed: #{e.message}"
    logger.error e.backtrace.join("\n")
    exit 1
  end
  
when 'all'
  # Start all services
  logger.info "Starting all services in separate processes..."
  
  # Start health check service
  health_pid = Process.fork do
    exec "ruby #{__FILE__} health"
  end
  
  # Start dashboard
  dashboard_pid = Process.fork do
    exec "ruby #{__FILE__} dashboard"
  end
  
  # Start main bot
  bot_pid = Process.fork do
    exec "ruby #{__FILE__} bot"
  end
  
  logger.info "All services started. PIDs: bot=#{bot_pid}, health=#{health_pid}, dashboard=#{dashboard_pid}"
  
  # Monitor child processes
  Process.waitall
else
  puts "Unknown command: #{ARGV[0]}"
  puts "Usage: ruby startup.rb [bot|dashboard|health|all]"
  puts "  bot       - Start the PugBot Discord bot"
  puts "  dashboard - Start the Telemetry Dashboard web interface"
  puts "  health    - Start the Health Check service"
  puts "  all       - Start all services"
  exit 1
end
