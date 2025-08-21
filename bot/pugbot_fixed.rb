#!/usr/bin/env ruby

require 'rexml/document'
require 'discordrb'
require 'dotenv/load'
require 'logger'

# Load models and services
require_relative 'config/database'
require_relative 'models/player'
require_relative 'models/match'
require_relative 'services/queue_service'
require_relative 'services/aws_service'
require_relative 'services/ai_service'

class PugBot

  MAX_QUEUE_SIZE = 8 # Define constant for queue size

  def initialize
    @bot = Discordrb::Commands::CommandBot.new(
      token: ENV['DISCORD_PUG_BOT_TOKEN'],
      client_id: ENV['DISCORD_PUG_CLIENT_ID'],
      prefix: '!',
      advanced_functionality: true
    )

    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO

    @queue_service = QueueService.instance
    @aws_service = AwsService.new
    @ai_service = AiService.new

    @map_votes = Hash.new(0) # Initialize map votes
    @active_server_instance = nil # Initialize active server instance

    setup_commands
    setup_events
  end

  def setup_commands
    # Queue management commands
    @bot.command(:join) do |event|
      result = @queue_service.add_player(event.user)

      if result[:success]
        event << "Success: #{result[:message]}"

        # Send queue status
        status = @queue_service.queue_status
        if status[:size] > 0
          queue_list = status[:players].map.with_index(1) do |p, i|
            "#{i}. #{p[:display_name]} (#{p[:region]}) - #{p[:time_waiting]}"
          end.join("\n")
          
          event << "📋 **Current Queue (#{status[:size]}/#{status[:max_size]}):**\n#{queue_list}"
        end

        # Check if ready check should start
        if status[:size] >= MAX_QUEUE_SIZE
          event << "🚨 **Queue is full! Starting ready check...**"
          event << "Type `!ready` within 60 seconds to confirm you're ready to play!" #Consider a configurable timeout.
          
          # Mention all queued players
          mentions = status[:players].map { |p| "<@#{p[:discord_id]}>" }.join(' ')
          event << "#{mentions} - Ready check active!"
        end
      else
        event << "Error: #{result[:message]}"
      end
    end

    @bot.command(:leave) do |event|
      result = @queue_service.remove_player(event.user)
      event << result[:success] ? "Success: #{result[:message]}" : "Error: #{result[:message]}"
    end

    @bot.command(:ready) do |event|
      result = @queue_service.player_ready(event.user)

      if result[:success]
        event << "Success: #{result[:message]}"

        # Check if match should start
        ready_status = @queue_service.ready_status
        if ready_status && ready_status[:ready_count] >= MAX_QUEUE_SIZE # Use constant
          event << "🎮 **All players ready! Creating match...**"
          start_match(event)
        elsif ready_status
          remaining = 8 - ready_status[:ready_count]
          event << "⏳ Waiting for #{remaining} more players to ready up..."
        end
      else
        event << "Error: #{result[:message]}"
      end
    end

    @bot.command(:unready) do |event|
      result = @queue_service.player_unready(event.user)
      event << result[:success] ? "Success: #{result[:message]}" : "Error: #{result[:message]}"
    end

    @bot.command(:status) do |event|
      status = @queue_service.queue_status

      if status[:size] == 0
        event << "📋 **Queue is empty.** Type `!join` to start a game!"
      else #consider adding an "else if" for a case where status[:size] is negative which doesn't make sense
        queue_list = status[:players].map.with_index(1) do |p, i|
          "#{i}. #{p[:display_name]} (#{p[:region]}) - #{p[:time_waiting]}"
        end.join("\n")
        
        embed = Discordrb::Webhooks::Embed.new(
          title: "Status: PUG Queue Status",
          description: "**Current Queue (#{status[:size]}/#{status[:max_size]}):**\n#{queue_list}",
          color: status[:size] >= 8 ? 0x00ff00 : 0xffa500,
          timestamp: Time.now
        )

        if status[:ready_check_active]
          ready_status = @queue_service.ready_status
          embed.add_field(
            name: "🚨 Ready Check Active",
            value: "Ready: #{ready_status[:ready_count]}/8\nWaiting: #{ready_status[:players_waiting].join(', ')}",
            inline: false
          )
        end

        event.channel.send_embed('', embed)
      end
    end

    # Server management commands  
    @bot.command(:startserver) do |event, map_name = 'dm4'|
      if @active_server_instance
        event << "A server is already active and attached to the bot: IP #{@active_server_instance[:public_ip]}"
        return
      end

      event << "Starting: **Starting FortressOne server...**"
      event << "Map: #{map_name}"
      event << "Region: Sydney (AU)" #This needs to be configurable

      result = @aws_service.deploy_server('Sydney', map_name)

      if result[:success]
        @active_server_instance = {
          instance_id: result[:instance_id],
          public_ip: result[:public_ip],
          status: result[:status]
        }
        event << "Success: **Server deployment initiated!**"
        event << "Instance ID: #{result[:instance_id]}"
        event << "Status: #{result[:status]}"
        event << "⏳ Server will be ready in ~2-3 minutes... Once ready, it will be attached to the bot."
      else
        event << "Error: **Failed to start server:** #{result[:error]}"
      end
    end
    
    @bot.command(:servers) do |event|
      servers = @aws_service.list_active_servers

      if servers.empty?
        event << "📋 **No active servers.**"
      else
        server_list = servers.map do |server|
          "🖥️ **#{server[:region]} Server**\n" +
          "IP: #{server[:public_ip]}:27500\n" +
          "Status: #{server[:status]}\n" +
          "Uptime: #{server[:uptime]}\n" +
          "Players: #{server[:player_count]}"
        end.join("\n\n")

        event << "🌐 **Active Servers:**\n#{server_list}"
      end
    end

    @bot.command(:serverstatus) do |event|
      if @active_server_instance
        event << "Attached Server Status:"
        event << "Instance ID: #{@active_server_instance[:instance_id]}"
        event << "Public IP: #{@active_server_instance[:public_ip]}"
        event << "Status: #{@active_server_instance[:status]}"
        # Optionally, fetch real-time status from AWS for the attached server
        # current_status = @aws_service.get_server_status(@active_server_instance[:instance_id])
        # event << "Current AWS Status: #{current_status}"
      end

      servers = @aws_service.list_active_servers

      if servers.empty? && !@active_server_instance
        event << "📋 **No active servers.**"
      elsif !servers.empty?
        server_list = servers.map do |server|
          "🖥️ **#{server[:region]} Server**\n" +
          "Instance ID: #{server[:aws_instance_id]}\n" +
          "Public IP: #{server[:public_ip]}\n" +
          "Status: #{server[:status]}\n" +
          "Uptime: #{server[:uptime]}\n" +
          "Players: #{server[:player_count]}"
        end.join("\n\n")

        event << "🌐 **FortressOne Server Status (All Active):**\n#{server_list}"
      end
    end

    @bot.command(:stopserver) do |event, server_id_or_attached_flag = nil|
      target_server_id = nil

      if server_id_or_attached_flag == 'attached' && @active_server_instance
        target_server_id = @active_server_instance[:instance_id]
        event << "Attempting to stop the attached server: #{target_server_id}"
      elsif server_id_or_attached_flag
        target_server_id = server_id_or_attached_flag
        event << "Attempting to stop server with ID: #{target_server_id}"
      elsif @active_server_instance
        target_server_id = @active_server_instance[:instance_id]
        event << "No server ID provided, stopping the attached server: #{target_server_id}"
      else
        event << "Error: Please provide the server ID to stop, or type `!stopserver attached` to stop the currently attached server."
        return
      end

      result = @aws_service.terminate_server(target_server_id)

      if result[:success]
        if @active_server_instance && @active_server_instance[:instance_id] == target_server_id
          @active_server_instance = nil # Detach the server
          event << "Success: Attached server #{target_server_id} has been stopped and detached."
        else
          event << "Success: Server #{target_server_id} has been stopped."
        end
      else
        event << "Error: Failed to stop server #{target_server_id}: #{result[:error]}"
      end
    end

    # Player statistics
    @bot.command(:profile) do |event, mentioned_user = nil|
      target_user = mentioned_user ? event.message.mentions.first : event.user
      player = Player.find(discord_id: target_user.id.to_s)

      unless player
        event << "Error: **Player not found.** Play some matches first!"
        return
      end

      profile = player.profile_summary

      embed = Discordrb::Webhooks::Embed.new(
        title: "👤 Player Profile: #{profile[:display_name]}",
        color: 0x0099ff,
        thumbnail: Discordrb::Webhooks::EmbedThumbnail.new(url: target_user.avatar_url),
        timestamp: Time.now
        )

      embed.add_field(name: "🌍 Region", value: profile[:region], inline: true) #TODO make sure region comes from the database
      embed.add_field(name: "🎮 Total Matches", value: profile[:total_matches], inline: true)
      embed.add_field(name: "🏆 Win Rate", value: profile[:win_rate], inline: true)
      embed.add_field(name: "⚔️ Average Frags", value: profile[:avg_frags] || 'N/A', inline: true)
      embed.add_field(name: "👀 Last Seen", value: profile[:last_seen] || 'Never', inline: true)

      event.channel.send_embed('', embed)
    end

    @bot.command(:setlocation) do |event, country_code|
      unless country_code
        event << "Error: Please provide a 2-letter country code (e.g., AU, US)."
        return
      end

      player = Player.find_or_create_by_discord(event.user)
      result = player.set_country_code(country_code)
      event << result[:message]
    end

    # AI-powered commands
    @bot.command(:analyze) do |event, *args|
      query = args.join(' ')
      return event << "Error: **Please provide a query to analyze.**" if query.empty?

      event << "Bot: **Analyzing:** #{query}"

      begin
        response = @ai_service.analyze_query(query, event.user)
        event << "📊 **Analysis:**\n#{response}"
      rescue => e
        @logger.error "AI analysis failed: #{e.inspect}"
        event << "Error: **AI analysis failed:** #{e.message}"
      end
    end

    # Help command
    @bot.command(:help) do |event|
      embed = Discordrb::Webhooks::Embed.new(
        title: "PugBot Commands",
        description: "Here is a list of available commands:",
        color: 0x0099ff
      )

      embed.add_field(name: "!join", value: "Join the queue to play a PUG.", inline: false)
      embed.add_field(name: "!leave", value: "Leave the queue.", inline: false)
      embed.add_field(name: "!status", value: "Check the current queue status.", inline: false)
      embed.add_field(name: "!ready", value: "Mark yourself as ready to play.", inline: false)
      embed.add_field(name: "!unready", value: "Mark yourself as not ready.", inline: false)
      embed.add_field(name: "!profile", value: "View your player profile.", inline: false)
      embed.add_field(name: "!setlocation [country_code]", value: "Set your location (e.g., !setlocation US).", inline: false)
      embed.add_field(name: "!startserver [map_name]", value: "Start a new FortressOne server (e.g., !startserver dm4).", inline: false)
      embed.add_field(name: "!servers", value: "List all active servers.", inline: false)
      embed.add_field(name: "!serverstatus", value: "Get the status of all active servers.", inline: false)
      embed.add_field(name: "!stopserver [server_id]", value: "Stop a server.", inline: false)
      embed.add_field(name: "!analyze [query]", value: "Analyze a query using AI.", inline: false)
      embed.add_field(name: "!ask [question]", value: "Ask the bot a question.", inline: false)

      event.channel.send_embed(' ', embed)
    end
    # Operator emergency procedures
    @bot.command(:'help-ops') do |event|
      embed = Discord::Embed.new
      embed.title = "🚨 OPERATOR EMERGENCY PROCEDURES"
      embed.description = "**CRITICAL OPERATIONAL CHEAT SHEET**"
      embed.color = 0xFF0000

      embed.add_field(name: "🔥 MATCH STUCK/BROKEN", value: "`!reset` - Reset queue\n`!forcestart` - Force match start\n`!status` - Check current state", inline: false)
      embed.add_field(name: "👥 PLAYER ISSUES", value: "`!add @user` - Force add user\n`!remove @user` - Force remove user\n`!substitute @old @new` - Swap players", inline: false) 
      embed.add_field(name: "🎯 SERVER PROBLEMS", value: "`!validate` - Check server status\n`!reconnect` - Restart bot connection\n`!emergency-stop` - Full system halt", inline: false)
      embed.add_field(name: "📊 DIAGNOSTICS", value: "`!queue-dump` - Export queue state\n`!logs recent` - Get error logs\n`!health-check` - System status", inline: false)
      embed.add_field(name: "⚡ ESCALATION", value: "**Level 1:** Reset queue, check status\n**Level 2:** Force restart, validate servers\n**Level 3:** Emergency stop, contact devs", inline: false)
      embed.add_field(name: "🆘 PANIC BUTTON", value: "If all else fails: `!emergency-stop`\nThen contact @TimBauer immediately", inline: false)

      event.channel.send_embed(' ', embed)
    end


    # AI-powered command with cooldown
    @bot.command(:ask, bucket: :ask, rate_limit_message: 'You are on cooldown for %time% seconds.', rate_limit: 60) do |event, *args|
      query = args.join(' ')
      return event << "Error: **Please provide a question to ask.**" if query.empty?

      event << "Bot: **Thinking about:** #{query}"

      begin
        response = @ai_service.analyze_query(query, event.user)
        event << "🤖 **Answer:**\n#{response}"
      rescue => e
        @logger.error "AI query failed: #{e.inspect}"
        event << "Error: **AI query failed:** #{e.message}"
      end
    end

    # Admin commands
    @bot.command(:reset, required_roles: ['Admin', 'Moderator']) do |event|
      @queue_service.reset_queue
      event << "Success: **Queue has been reset by admin.**"
    end

    @bot.command(:forcestart, required_roles: ['Admin', 'Moderator']) do |event|
      if @queue_service.queue_status[:size] < 4
        event << "Error: **Need at least 4 players to force start a match.**"
        return
      end

      event << "⚡ **Admin force starting match...**"
      start_match(event, force: true)
    end

    @bot.command(:cleanup, required_roles: ['Admin', 'Moderator']) do |event|
      result = @aws_service.terminate_all_servers
      event << "Success: Terminated #{result[:terminated_count]} servers."
    end

    @bot.command(:ban, required_roles: ['Admin', 'Moderator']) do |event, mentioned_user|
      unless mentioned_user
        event << "Error: Please mention a user to ban."
        return
      end

      target_user = event.message.mentions.first
      player = Player.find(discord_id: target_user.id.to_s)

      unless player
        event << "Error: Player not found."
        return
      end

      player.ban!
      event << "Success: #{player.username} has been banned."
    end

    @bot.command(:unban, required_roles: ['Admin', 'Moderator']) do |event, mentioned_user|
      unless mentioned_user
        event << "Error: Please mention a user to unban."
        return
      end

      target_user = event.message.mentions.first
      player = Player.find(discord_id: target_user.id.to_s)

      unless player
        event << "Error: Player not found."
        return
      end

      player.unban!
      event << "Success: #{player.username} has been unbanned."
    end
  end

   def setup_events
    @bot.ready do |event|
      @logger.info "PUG Bot Ready! Logged in as #{@bot.profile.username}##{@bot.profile.discriminator}"
      @logger.info "Bot is running in #{@bot.servers.count} servers"
      
      @bot.servers.each do |id, server|
        @logger.info "Connected to server: #{server.name} (ID: #{id})"
        
        # Find #pugbot channel
        pugbot_channel = server.channels.find { |c| c.name == 'pugbot' }
        if pugbot_channel
          @logger.info "Found #pugbot channel in #{server.name}"
          pugbot_channel.send_message("Bot: **PUG Bot is online and ready!**\nType `!join` to start playing!")
        end
      end

      # Set bot activity
      @bot.game = "Type !join to play | #{@queue_service.queue_status[:size]}/8 in queue"
    end

    @bot.member_join do |event|
      @logger.info "New member joined: #{event.user.username}"

      # Create player record
      Player.find_or_create_by_discord(event.user)

      # Send welcome message in general channel
      general = event.server.general_channel
      general&.send_message("👋 Welcome #{event.user.mention}! Head to #pugbot and type `!join` to start playing!")
    end

    # Update bot activity
    Thread.new do
      loop do
        sleep(30)
        begin
          queue_size = @queue_service.queue_status[:size]
          @bot.game = "Type !join to play | #{queue_size}/8 in queue"
        rescue StandardError => e
          @logger.error "Failed to update bot activity: #{e.inspect}"
        end
      end
    end
  end

  def start_match(event, force: false)
    begin
      # Get match data from queue
      match_data = force ? @queue_service.force_create_match : @queue_service.get_ready_match # consider better naming

      return event << "Error: **No match ready to start.**" unless match_data

      # Start server
      server_result = @aws_service.deploy_server(match_data[:region], 'dm4')

      unless server_result[:success]
        event << "Error: **Failed to start server:** #{server_result[:error]}" #Potentially retry
        return #Consider a retry mechanism
      end
      
      # Create match record
      match = Match.create_new_match(
        server_result[:instance_id],
        'dm4',
        match_data[:region]
      )
      
      match.add_players(match_data[:players].map { |p| p[:player] })
      
      # Announce match
      embed = Discordrb::Webhooks::Embed.new(
        title: "🎮 Match Started!",
        description: "Server is starting up...",
        color: 0x00ff00,
        timestamp: Time.now
      )

      red_team = match.red_team.map(&:username).join(', ')
      blue_team = match.blue_team.map(&:username).join(', ')
      
      embed.add_field(name: "🔴 Red Team", value: red_team, inline: false)
      embed.add_field(name: "🔵 Blue Team", value: blue_team, inline: false)
      embed.add_field(name: "🗺️ Map", value: 'dm4', inline: true)
      embed.add_field(name: "🌍 Region", value: match_data[:region], inline: true)
      embed.add_field(name: "⏳ Status", value: "Server starting...", inline: true)
      
      event.channel.send_embed('', embed)
      
      # Mention all players
      mentions = match_data[:players].map { |p| "<@#{p[:discord_user].id}>" }.join(' ')
      event << "#{mentions} - Your match is starting! Server details will be posted shortly."

    rescue => e
      @logger.error "Failed to start match: #{e.inspect}" #Include backtrace for debugging
      event << "Error: **Failed to start match:** #{e.message}"
    end
  end
  
  def run
    @bot.run
  end
end

# Start the bot
if __FILE__ == $0
  bot = PugBot.new

  bot.run
end
