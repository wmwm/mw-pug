#!/usr/bin/env ruby

# Enhanced Help Command for QWTF Parity Bot
# Integrates command manifest with QWTF-style aliases

class HelpOpsCommand
  def initialize(config, command_alias_service)
    @config = config
    @alias_service = command_alias_service
  end

  def generate_help_embed(command = nil)
    if command
      generate_command_help(command)
    else
      generate_full_help
    end
  end

  private

  def generate_full_help
    # List of all commands (code-formatted, inline, for easy scanning)
      all_commands = %w[help join leave queue status server deploy terminate list ++ --]
      command_list = all_commands.map { |cmd| "`#{cmd}`" }.join('   ')

      embed = {
        title: "Commands Reference",
        description: "**Bot supports all commands in every regional pug channel (e.g., #oceania, #north-america, #europe).**\nEach channel has its own queue, teams, and voice channels.\n\n**Quick Reference:**\n```
      or !join     → Join queue
      or !leave    → Leave queue
      !queue           → Show the current queue
      !status          → Show match/server status
      !map <name>      → Vote/force map
      !server <region> → Set server region
      ```\n\n**Full Command List:**\n`!help`, `!join`, `!leave`, `!queue`, `!status`, `!server`, `!deploy`, `!terminate`, `!list`, `++`, `--`\n\n**Use `!help <command>` for details.**",
  +   or !join     → Join queue (works in any pug channel)
    embed[:fields] << {
      name: "📋 Queue Management", 
      value: "`\n!join, !tpg, ++  → Join the active queue\n!leave, !ntpg, -- → Leave the active queue\n!queue           → Move to back of queue\n!status          → Display PUG status\n!team            → Show team assignments\n`",
      inline: true
    }
      embed = {
        title: "Commands Reference",
        description: "**Bot supports all commands in every regional pug channel (e.g., #oceania, #north-america, #europe).**\nEach channel has its own queue, teams, and voice channels.\n\n**Quick Reference:**\n```
  +   or !join     → Join queue
      name: "🎮 Match Control",
      value: "`\n!start     → Start a game\n!end       → End current match\n!requeue   → Cancel and re-add players\n!choose    → Pick teams manually\n!transfer  → Move player to other team\n!merge     → Merge queues/teams\n`",
      inline: true
    }

        color: 0x00ff00,
        fields: [
          {
            name: "General Commands",
            value: "```
    # Map & Server Control
    embed[:fields] << {
      name: "🗺️ Maps & Servers",
      value: "`\n!map <name>    → Set/vote for map\n!maps          → List available maps\n!server <region> → Set preferred server\n!instances     → List server instances\n!up <server>   → Bring up server (AWS/EC2)\n!down <server> → Shut down server (AWS/EC2)\n`",
      inline: false
            inline: false
          },
          {
            name: "Server Management",
            value: "```
    }

    # AWS/Server Management
    embed[:fields] << {
      name: "☁️ AWS Server Management",
            inline: false
          },
          {
            name: "Match & Map Control",
            value: "```
      value: "`\n!up <server> [options]     → Deploy/start a new AWS EC2 game server\n!down <server>            → Terminate a running AWS EC2 server\n!instances                → List all active AWS EC2 servers\n!status <server>          → Show status and public IP of a server\n!terminateall             → Terminate all running AWS EC2 servers\n`\n\n**Options:**\n- region: Specify AWS region (default: ap-southeast-2)\n- map: Set map name (default: dm4)\n- hostname: Set server hostname\n- instance_type: EC2 type (default: t2.micro)\n\n**Examples:**\n- !up sydney1 map=dm6 region=ap-southeast-2\n- !down sydney1\n- !instances\n- !status sydney1\n- !terminateall\n",
      inline: false
    }

    # Enhanced Features
            inline: false
          },
          {
            name: "Advanced Features",
            value: "```
    embed[:fields] << {
      name: "⚡ Enhanced Features",
      value: "`\n!notify-level [low|normal|verbose] → Set notification preferences\n!notify-audit [days]              → View notification analytics\n!league_elos                      → Show ELO standings\n!voice                           → Join voice channel\n!psyncroles                      → Sync Discord roles\n`",
      inline: false
    }
            inline: false
          }
        ]
      }

    # Admin Commands
    embed[:fields] << {
      name: "🔧 Admin Commands",
      value: "`\n!show <setting>  → Show bot settings\n!set <setting>   → Change bot setting\n!force_restart   → Force match restart\n!instance <id>   → Show server details\n`",
      inline: true
    }

    # QWTF Workflow
    embed[:fields] << {
      name: "🎯 QWTF.live Workflow",
      value: "**1.** Players join with ++\n**2.** Vote for map with !map <name>\n**3.** Teams auto-balanced\n**4.** Server auto-selected\n**5.** Match starts with connect info",
      inline: false
    }

    embed[:footer] = {
      text: "💡 Tip: Use !help <command> for detailed info about specific commands"
    }

    embed
  end

  def generate_command_help(command)
    command_info = @alias_service.get_command_info(command)
    
    unless command_info
      return {
        title: "❌ Command Not Found",
        description: "Command #{command} not recognized. Use !help for available commands.",
        color: 0xff0000
      }
    end

    embed = {
      title: "📖 Command: #{command_info[:canonical]}",
      description: command_info[:description],
      color: 0x0099ff,
      fields: []
    }

    # Show aliases
    if command_info[:aliases].any?
      aliases_text = command_info[:aliases].map { |a| "#{a}" }.join(", ")
      embed[:fields] << {
        name: "🔄 Aliases",
        value: aliases_text,
        inline: false
      }
    end

    # QWTF-specific info
    if command_info[:qwtf_syntax]
      embed[:fields] << {
        name: "🎯 QWTF.live Compatible",
        value: "This command uses the same syntax as QWTF.live for seamless migration.",
        inline: false
      }
    end

    # Module info
    embed[:fields] << {
      name: "📦 Module",
      value: "#{command_info[:module]}",
      inline: true
    }

    # Usage examples based on command
    case command_info[:canonical]
    when 'join'
      embed[:fields] << {
        name: "💡 Usage Examples",
        value: "`\n++           → Quick join (QWTF style)\n!tpg         → Alternative join\n!join        → Standard join\n!add         → Another alias\n`",
        inline: false
      }
    when 'leave'
      embed[:fields] << {
        name: "💡 Usage Examples", 
        value: "`\n--           → Quick leave (QWTF style)\n!ntpg        → Alternative leave\n!leave       → Standard leave\n!remove      → Another alias\n`",
        inline: false
      }
    when 'map'
      embed[:fields] << {
        name: "💡 Usage Examples",
        value: "`\n!map dm6     → Vote for/force dm6\n!map         → Show current map\n!forcemap q3dm17 → Force map selection\n`",
        inline: false
      }
    when 'server'
      embed[:fields] << {
        name: "💡 Usage Examples",
        value: "`\n!server eu_west  → Prefer EU West\n!server na_east  → Prefer NA East\n!server oceania  → Prefer Oceania\n!server          → Show current server\n`",
        inline: false
      }
    when 'notify'
      embed[:fields] << {
        name: "💡 Usage Examples",
        value: "`\n!notify              → Ping all queue players\n!notify-level low    → Set minimal notifications\n!notify-level verbose → Set all notifications\n!notify-audit 7      → Show 7-day audit log\n`",
        inline: false
      }
    end

    embed
  end

  def get_qwtf_migration_help
    {
      title: "🎯 QWTF.live → This Bot migration Guide",
      description: "All your familiar commands work exactly the same!",
      color: 0x00ff00,
      fields: [
        {
          name: "✅ Identical Commands",
          value: "`\n++      → Join queue (exactly the same)\n--      → Leave queue (exactly the same)\n!tpg    → Join queue (exactly the same)\n!ntpg   → Leave queue (exactly the same)\n!map    → Map voting (exactly the same)\n!server → Server selection (exactly the same)\n`",
          inline: false
        },
        {
          name: "⚡ Enhanced Commands",
          value: "`\n!notify → Now with user preferences\n!status → Enhanced with ELO info\n!help   → Comprehensive command guide\n`",
          inline: false
        },
        {
          name: "🆕 New Features",
          value: "`\n!notify-level    → Control notification verbosity\n!league_elos     → View competitive standings\n!instances       → Manage on-demand servers\n!voice           → Auto voice channel joining\n`",
          inline: false
        },
        {
          name: "🎮 Workflow (Unchanged)",
          value: "**1.** Join with ++\n**2.** Vote map with !map <name>\n**3.** Teams auto-picked\n**4.** Server auto-assigned\n**5.** Match starts",
          inline: false
        }
      ],
      footer: {
        text: "🚀 Zero learning curve - everything works as expected!"
      }
    }
  end
end
