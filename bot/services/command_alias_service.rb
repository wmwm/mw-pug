# Enhanced Command Alias Service for QWTF Parity
# Integrates with command manifest for complete alias resolution

class CommandAliasService
  def initialize(config)
    @config = config
    @aliases = config.dig('pug_bot', 'command_aliases') || {}
    @command_manifest = load_command_manifest
  end

  def resolve_alias(command)
    # First check QWTF-style aliases from config
    @aliases.each do |canonical, aliases|
      return canonical if aliases.include?(command)
    end
    
    # Then check command manifest aliases
    @command_manifest.each do |cmd, details|
      if details['aliases'] && details['aliases'].include?(command)
        return cmd
      end
    end
    
    # Return original command if no alias found
    command
  end

  def handle_special_syntax(message)
    content = message.strip
    
    case content
    when '++'
      'join'
    when '--' 
      'leave'
    else
      nil
    end
  end

  def is_alias?(command)
    # Check QWTF aliases
    return true if @aliases.values.flatten.include?(command)
    
    # Check manifest aliases
    @command_manifest.each do |_, details|
      return true if details['aliases'] && details['aliases'].include?(command)
    end
    
    false
  end

  def get_aliases(canonical_command)
    aliases = []
    
    # Add QWTF aliases
    aliases.concat(@aliases[canonical_command] || [])
    
    # Add manifest aliases
    if @command_manifest[canonical_command] && @command_manifest[canonical_command]['aliases']
      aliases.concat(@command_manifest[canonical_command]['aliases'])
    end
    
    aliases.uniq
  end

  def get_command_info(command)
    canonical = resolve_alias(command)
    manifest_entry = @command_manifest[canonical]
    
    return nil unless manifest_entry
    
    {
      canonical: canonical,
      description: manifest_entry['description'],
      module: manifest_entry['module'],
      aliases: get_aliases(canonical),
      qwtf_syntax: ['join', 'leave'].include?(canonical)
    }
  end

  def list_qwtf_commands
    qwtf_commands = []
    
    @aliases.each do |canonical, aliases|
      if @command_manifest[canonical]
        qwtf_commands << {
          command: canonical,
          aliases: aliases,
          description: @command_manifest[canonical]['description'],
          qwtf_style: aliases.any? { |a| ['++', '--', '!tpg', '!ntpg'].include?(a) }
        }
      end
    end
    
    qwtf_commands
  end

  private

  def load_command_manifest
    # Command manifest integrated directly
    {
      'help' => {
        'description' => 'Show available commands and usage',
        'aliases' => [],
        'module' => 'help_docs'
      },
      'join' => {
        'description' => 'Join the active queue',
        'aliases' => ['++', '!tpg', '!add'],
        'module' => 'queue'
      },
      'leave' => {
        'description' => 'Leave the active queue', 
        'aliases' => ['--', '!ntpg', '!remove'],
        'module' => 'queue'
      },
      'queue' => {
        'description' => 'Move yourself or a specified player to the back of the queue',
        'aliases' => [],
        'module' => 'queue_management'
      },
      'requeue' => {
        'description' => 'Cancel current game and re-add all players to queue',
        'aliases' => [],
        'module' => 'match_control'
      },
      'team' => {
        'description' => 'Show current team assignments',
        'aliases' => [],
        'module' => 'match_status'
      },
      'status' => {
        'description' => 'Display current PUG status',
        'aliases' => [],
        'module' => 'match_status'
      },
      'start' => {
        'description' => 'Start a game with an optional team size',
        'aliases' => [],
        'module' => 'match_control'
      },
      'choose' => {
        'description' => 'Pick teams manually',
        'aliases' => [],
        'module' => 'match_control'
      },
      'map' => {
        'description' => 'Set or vote for a map',
        'aliases' => [],
        'module' => 'map_control'
      },
      'server' => {
        'description' => 'Set preferred server',
        'aliases' => [],
        'module' => 'server_control'
      },
      'end' => {
        'description' => 'End a match and clear the queue',
        'aliases' => [],
        'module' => 'match_control'
      },
      'notify' => {
        'description' => 'Ping players for an active pug',
        'aliases' => [],
        'module' => 'notify_service'
      },
      'voice' => {
        'description' => 'Join or move to the linked voice channel',
        'aliases' => [],
        'module' => 'voice_link'
      },
      'force_restart' => {
        'description' => 'Force a restart of the current match',
        'aliases' => [],
        'module' => 'match_control'
      },
      'transfer' => {
        'description' => 'Move a player to the other team',
        'aliases' => [],
        'module' => 'match_control'
      },
      'instances' => {
        'description' => 'List on-demand servers',
        'aliases' => [],
        'module' => 'server_control'
      },
      'up' => {
        'description' => 'Bring up an on-demand server',
        'aliases' => [],
        'module' => 'server_control'
      },
      'down' => {
        'description' => 'Shut down an on-demand server',
        'aliases' => [],
        'module' => 'server_control'
      },
      'instance' => {
        'description' => 'Show details for a specific server instance',
        'aliases' => [],
        'module' => 'server_control'
      },
      'maps' => {
        'description' => 'List available maps',
        'aliases' => [],
        'module' => 'map_control'
      },
      'league_elos' => {
        'description' => 'Show league ELO standings',
        'aliases' => [],
        'module' => 'stats'
      },
      'show' => {
        'description' => 'Show configurable bot settings',
        'aliases' => [],
        'module' => 'settings'
      },
      'set' => {
        'description' => 'Change a bot setting',
        'aliases' => [],
        'module' => 'settings'
      },
      'merge' => {
        'description' => 'Merge queues or teams',
        'aliases' => [],
        'module' => 'match_control'
      },
      'psyncroles' => {
        'description' => 'Sync your Discord roles with platform data',
        'aliases' => [],
        'module' => 'role_sync'
      }
    }
  end
end
