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
  stdout, stderr, status = docker_cmd('ps -q')
  return false if stderr&.include?('docker executable not found')
  status.success? && !stdout.strip.empty?
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
    prefix = @docker_host ? "DOCKER_HOST=#{@docker_host} " : ''
    full_cmd = "#{prefix}docker compose -f #{@compose_file} #{cmd}"
    Open3.capture3(full_cmd)
  end

  def start_server(map: '2fort', region: nil)
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
    path_entries = ENV['PATH']&.split(File::PATH_SEPARATOR) || []
    @docker_present = path_entries.any? do |p|
      exe = File.join(p, 'docker')
      File.exist?(exe) || File.exist?(exe + (Gem.win_platform? ? '.exe' : ''))
    end
    @docker_checked = true
    @docker_present
  end

end
