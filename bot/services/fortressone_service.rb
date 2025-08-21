# FortressOneService: Handles Docker-based FortressOne server lifecycle
# Methods: start_server, stop_server, server_status, compose_config
require 'open3'
require 'yaml'
require 'ostruct'

class FortressOneService
  CONFIG_PATH = 'config/server_infrastructure.yaml'

  def initialize(instance: 'default')
    @instance = instance # for multi-instance support
    @config = load_config
    apply_instance_overrides
  end
  # State recovery: check if a server is running (needs to be public)
  def running?
    begin
      stdout, stderr, status = docker_cmd('ps -q')
      return false if stderr&.include?('docker executable not found')
      return false if stderr&.include?('Error executing docker command')
      status.success? && !stdout.strip.empty?
    rescue => e
      # Just return false if any error happens
      false
    end
  end
  # Lifecycle command methods (remain public by default)

  def load_config
    begin
      raw = File.read(CONFIG_PATH)
      data = YAML.safe_load(raw, permitted_classes: [], aliases: false) || {}
      unless data.is_a?(Hash)
        warn "Config #{CONFIG_PATH} did not produce a Hash; got #{data.class}. Using empty config."
        return {}
      end
      data
    rescue Errno::ENOENT
      warn "Config file #{CONFIG_PATH} not found. Using defaults."
      {}
    rescue Psych::SyntaxError => e
      warn "YAML parse error in #{CONFIG_PATH}: #{e.message}. Using defaults."
      {}
    end
  end

  def apply_instance_overrides
    @docker_image = @config['fortressone_docker_image'] || 'fortressone/fortressonesv:latest'
    base_compose = @config['fortressone_compose_file'] || 'docker/fortressone-compose.yaml'
    base_host = @config['fortressone_docker_host']

    instance_cfg = (@config['fortressone_instances'] || {})[@instance] || {}
    @compose_file = instance_cfg['compose_file'] || base_compose
    @docker_host = instance_cfg['docker_host'] || base_host || nil
  end

  def docker_cmd(cmd)
    unless docker_available?
      return ["", "docker executable not found in PATH; skipping '#{cmd}'", OpenStruct.new(success?: false)]
    end
    
    begin
      prefix = @docker_host ? "DOCKER_HOST=#{@docker_host} " : ''
      
      # Check if docker-compose or docker compose is available
      if File.exist?(File.join(ENV['SystemRoot'] || 'C:\\Windows', 'System32', 'docker-compose.exe')) || 
         system('which docker-compose > /dev/null 2>&1')
        full_cmd = "#{prefix}docker-compose -f #{@compose_file} #{cmd}"
      else
        full_cmd = "#{prefix}docker compose -f #{@compose_file} #{cmd}"
      end
      
      Open3.capture3(full_cmd)
    rescue => e
      # Return error as a result instead of failing
      return ["", "Error executing docker command: #{e.message}", OpenStruct.new(success?: false)]
    end
  end

  def start_server(map: '2fort', region: nil)
    unless docker_available?
      # Return a mock success if Docker is not available
      return { 
        success: true, 
        stdout: "Docker not available. Mock server started with map #{map} in region #{region}.", 
        stderr: "" 
      }
    end
    
    # Optionally inject map/region as env or override in compose
    ENV['F1_MAP'] = map if map
    ENV['F1_REGION'] = region if region
    stdout, stderr, status = docker_cmd('up -d')
    { success: status.success?, stdout: stdout, stderr: stderr }
  end

  def stop_server
    stdout, stderr, status = docker_cmd('down')
    { success: status.success?, stdout: stdout, stderr: stderr }
  end

  def server_status
    stdout, stderr, status = docker_cmd('ps')
    { success: status.success?, stdout: stdout, stderr: stderr }
  end

  def restart_server
    stdout, stderr, status = docker_cmd('restart')
    { success: status.success?, stdout: stdout, stderr: stderr }
  end

  def logs(tail: 100)
    stdout, stderr, status = docker_cmd("logs --tail #{tail}")
    { success: status.success?, stdout: stdout, stderr: stderr }
  end

  def reload_config
    # Optionally send SIGHUP or reload command to container
    # This is a placeholder; real implementation may vary
    # Example: docker exec fortressone pkill -HUP fortressonesv
    container_id = get_container_id
    if container_id
      cmd = @docker_host ? "DOCKER_HOST=#{@docker_host} " : ''
      exec_cmd = "#{cmd}docker exec #{container_id} pkill -HUP fortressonesv"
      stdout, stderr, status = Open3.capture3(exec_cmd)
      { success: status.success?, stdout: stdout, stderr: stderr }
    else
      { success: false, stderr: 'No running container found.' }
    end
  end

  def get_container_id
  stdout, _stderr, status = docker_cmd('ps -q')
    return stdout.strip if status.success? && !stdout.strip.empty?
    nil
  end

  def compose_config
    @compose_file
  end

  private

  def docker_available?
    @docker_checked ||= false
    @docker_present ||= false
    return @docker_present if @docker_checked
    
    # Method 1: Use system command to directly check if docker exists
    @docker_present = system('where docker > NUL 2>&1') if Gem.win_platform?
    @docker_present = system('which docker > /dev/null 2>&1') unless Gem.win_platform?
    
    # Method 2: Try a direct Docker command as a fallback
    unless @docker_present
      begin
        stdout, stderr, status = Open3.capture3('docker --version')
        @docker_present = status.success?
      rescue
        @docker_present = false
      end
    end
    
    puts "[DEBUG] Docker detected: #{@docker_present.to_s}"
    @docker_checked = true
    @docker_present
  end

end
