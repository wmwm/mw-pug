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
    @bot.command([:join, '++']) do |event|
      result = @queue_service.add_player(event.user)
      event.message.delete rescue nil
      if result[:success]
        show_queue_status(event)
      else
        event.respond(result[:message], ephemeral: true)
      end
    end

    @bot.command([:leave, '--']) do |event|
      result = @queue_service.remove_player(event.user)
      event.message.delete rescue nil
      if result[:success]
        show_queue_status(event)
      else
        event.respond(result[:message], ephemeral: true)
      end
    end

    @bot.command(:ready) do |event|
      result = @queue_service.player_ready(event.user)

      if result[:success]
        event.respond("✅ #{result[:message]}", ephemeral: true)

        ready_status = @queue_service.ready_status
        if ready_status && ready_status[:ready_count] >= MAX_QUEUE_SIZE
          event.respond "🎮 **All players ready! Creating match...**"
          start_match(event)
        elsif ready_status
          remaining = MAX_QUEUE_SIZE - ready_status[:ready_count]
          event.respond "⏳ Waiting for #{remaining} more players to ready up..."
        end
      else
        event.respond("❌ Error: #{result[:message]}", ephemeral: true)
      end
    end

    @bot.command(:unready) do |event|
      result = @queue_service.player_unready(event.user)
      event.respond(result[:success] ? "✅ #{result[:message]}" : "❌ #{result[:message]}", ephemeral: true)
    end

    @bot.command(:status) do |event|
      event.message.delete rescue nil
      show_queue_status(event)
    end

    # Server management commands
    @bot.command(:startserver) do |event, map_name = 'dm4'|
      event.respond "🚀 **Deploying new FortressOne server on AWS...**"

      # Call the AWS service to deploy the server
      result = @aws_service.deploy_server(map_name: map_name)

      if result[:success]
        embed = Discordrb::Webhooks::Embed.new(
          title: "✅ Server Deployed Successfully",
          color: 0x00ff00,
          fields: [
            { name: "Instance ID", value: result[:instance_id], inline: true },
            { name: "Region", value: result[:region], inline: true },
            { name: "Map", value: result[:map], inline: true },
            { name: "Status", value: result[:status], inline: true },
            { name: "Public IP", value: "`#{result[:public_ip]}`", inline: false },
            { name: "Connect", value: "`connect #{result[:public_ip]}:27500`", inline: false }
          ]
        )
        event.channel.send_embed(' ', embed)
      else
        event.respond "❌ **Failed to deploy server:** #{result[:error]}"
      end
    end

    @bot.command(:servers) do |event|
      servers = @aws_service.list_active_servers

      if servers.empty?
        event.respond "📋 **No active servers.** Type `!startserver` to create one."
      else
        embed = Discordrb::Webhooks::Embed.new(
          title: "🌐 Active FortressOne Servers",
          color: 0x0099ff,
          timestamp: Time.now
        )

        servers.each do |server|
          embed.add_field(
            name: "🖥️ #{server[:region]} Server (`#{server[:aws_instance_id]}`)",
            value: "Status: **#{server[:status]}**\n" \
                   "IP: `#{server[:public_ip]}`\n" \
                   "Uptime: #{server[:uptime]}\n" \
                   "Connect: `connect #{server[:public_ip]}:27500`",
            inline: false
          )
        end
        event.channel.send_embed('', embed)
      end
    end

    @bot.command(:serverstatus) do |event|
      servers = @aws_service.list_active_servers

      if servers.empty?
        event.respond "📋 **No active servers.**"
      else
        embed = Discordrb::Webhooks::Embed.new(
          title: "🌐 FortressOne Server Status",
          color: 0x0099ff,
          timestamp: Time.now
        )

        servers.each do |server|
          embed.add_field(
            name: "🖥️ #{server[:region]} Server (`#{server[:aws_instance_id]}`)",
            value: "Status: **#{server[:status]}**\n" \
                   "Public IP: `#{server[:public_ip]}`\n" \
                   "Uptime: #{server[:uptime]}\n" \
                   "Players: #{server[:player_count]}\n" \
                   "Connect: `connect #{server[:public_ip]}:27500`",
            inline: false
          )
        end
        event.channel.send_embed('', embed)
      end
    end

    @bot.command(:stopserver) do |event, server_id = nil|
      target_server_id = server_id

      unless target_server_id
        event.respond "Error: Please provide the server ID to stop. e.g. `!stopserver i-0123456789abcdef0`"
        return
      end

      event.respond "🛑 **Attempting to stop server...**"
      result = @aws_service.terminate_server(target_server_id)

      if result[:success]
        event.respond "✅ **Success:** Server `#{target_server_id}` termination initiated."
      else
        event.respond "❌ **Failed to stop server:** #{result[:error]}"
      end
    end

    # Player statistics
    @bot.command(:profile) do |event, mentioned_user = nil|
      target_user = mentioned_user ? event.message.mentions.first : event.user
      player = Player.find(discord_id: target_user.id.to_s)

      unless player
        event.respond "Error: **Player not found.** Play some matches first!"
        return
      end

      profile = player.profile_summary

      embed = Discordrb::Webhooks::Embed.new(
        title: "👤 Player Profile: #{profile[:display_name]}",
        color: 0x0099ff,
        thumbnail: Discordrb::Webhooks::EmbedThumbnail.new(url: target_user.avatar_url),
        timestamp: Time.now
        )

      embed.add_field(name: "🌍 Region", value: profile[:region], inline: true)
      embed.add_field(name: "🎮 Total Matches", value: profile[:total_matches], inline: true)
      embed.add_field(name: "🏆 Win Rate", value: profile[:win_rate], inline: true)
      embed.add_field(name: "⚔️ Average Frags", value: profile[:avg_frags] || 'N/A', inline: true)
      embed.add_field(name: "👀 Last Seen", value: profile[:last_seen] || 'Never', inline: true)

      event.channel.send_embed('', embed)
    end

    @bot.command(:setlocation) do |event, country_code|
      unless country_code
        event.respond "Error: Please provide a 2-letter country code (e.g., AU, US)."
        return
      end

      player = Player.find_or_create_by_discord(event.user)
      result = player.set_country_code(country_code)
      event.respond result[:message]
    end

    # AI-powered commands
    @bot.command(:analyze) do |event, *args|
      query = args.join(' ')
      return event.respond "Error: **Please provide a query to analyze.**" if query.empty?

      event.respond "Bot: **Analyzing:** #{query}"

      begin
        response = @ai_service.analyze_query(query, event.user)
        event.respond "📊 **Analysis:**\n#{response}"
      rescue => e
        @logger.error "AI analysis failed: #{e.inspect}"
        event.respond "Error: **AI analysis failed:** #{e.message}"
      end
    end

    # Help command
    @bot.command(:help) do |event|
      commands = [
        'help', 'join', 'leave', 'status', 'ready', 'unready', 'profile', 'setlocation',
        'startserver', 'servers', 'serverstatus', 'stopserver', 'analyze', 'ask',
        'reset', 'forcestart', 'cleanup', 'ban', 'unban'
      ]
      command_list = commands.map { |c| "`#{c}`" }.join(', ')
      response = "**List of commands:**\n#{command_list}"
      event.respond(response)
    end

    # AI-powered command with cooldown
    @bot.command(:ask, bucket: :ask, rate_limit_message: 'You are on cooldown for %time% seconds.', rate_limit: 60) do |event, *args|
      query = args.join(' ')
      return event.respond "Error: **Please provide a question to ask.**" if query.empty?

      event.respond "Bot: **Thinking about:** #{query}"

      begin
        response = @ai_service.analyze_query(query, event.user)
        event.respond "🤖 **Answer:**\n#{response}"
      rescue => e
        @logger.error "AI query failed: #{e.inspect}"
        event.respond "Error: **AI query failed:** #{e.message}"
      end
    end

    # Admin commands
    @bot.command(:reset, required_roles: ['Admin', 'Moderator']) do |event|
      @queue_service.reset_queue
      event.respond "Success: **Queue has been reset by admin.**"
    end

    @bot.command(:forcestart, required_roles: ['Admin', 'Moderator']) do |event|
      if @queue_service.queue_status[:size] < 4
        event.respond "Error: **Need at least 4 players to force start a match.**"
        return
      end

      event.respond "⚡ **Admin force starting match...**"
      start_match(event, force: true)
    end

    @bot.command(:cleanup, required_roles: ['Admin', 'Moderator']) do |event|
      result = @aws_service.terminate_all_servers
      event.respond "Success: Terminated #{result[:terminated_count]} servers."
    end

    @bot.command(:ban, required_roles: ['Admin', 'Moderator']) do |event, mentioned_user|
      unless mentioned_user
        event.respond "Error: Please mention a user to ban."
        return
      end

      target_user = event.message.mentions.first
      player = Player.find(discord_id: target_user.id.to_s)

      unless player
        event.respond "Error: Player not found."
        return
      end

      player.ban!
      event.respond "Success: #{player.username} has been banned."
    end

    @bot.command(:unban, required_roles: ['Admin', 'Moderator']) do |event, mentioned_user|
      unless mentioned_user
        event.respond "Error: Please mention a user to unban."
        return
      end

      target_user = event.message.mentions.first
      player = Player.find(discord_id: target_user.id.to_s)

      unless player
        event.respond "Error: Player not found."
        return
      end

      player.unban!
      event.respond "Success: #{player.username} has been unbanned."
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
      match_data = force ? @queue_service.force_create_match : @queue_service.get_ready_match

      return event.respond "Error: **No match ready to start.**" unless match_data

      # Start server
      server_result = @aws_service.deploy_server(match_data[:region], 'dm4')

      unless server_result[:success]
        event.respond "Error: **Failed to start server:** #{server_result[:error]}"
        return
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
      event.respond "#{mentions} - Your match is starting! Server details will be posted shortly."

    rescue => e
      @logger.error "Failed to start match: #{e.inspect}"
      event.respond "Error: **Failed to start match:** #{e.message}"
    end
  end

  def run
    @bot.run
  end

  private

  def show_queue_status(event)
    status = @queue_service.queue_status

    if status[:size] == 0
      description = "The queue is empty! Type `!join` or `++` to get started."
    else
      player_list = status[:players].map.with_index(1) do |p, i|
        "#{i}. `#{p[:display_name]}`"
      end.join("\n")
      description = "**Players in queue (#{status[:size]}/#{MAX_QUEUE_SIZE}):**\n#{player_list}"
    end

    embed = Discordrb::Webhooks::Embed.new(
      title: "Oceania - FortressOne PUG",
      description: description,
      color: 0x0099ff,
      timestamp: Time.now
    )

    if status[:ready_check_active]
      ready_status = @queue_service.ready_status
      embed.add_field(
        name: "🚨 Ready Check Active",
        value: "Ready: #{ready_status[:ready_count]}/#{MAX_QUEUE_SIZE}\nWaiting: #{ready_status[:players_waiting].join(', ')}",
        inline: false
      )
    end

    event.channel.send_embed('', embed)

    # Start ready check if queue is full
    if status[:size] >= MAX_QUEUE_SIZE && !status[:ready_check_active]
      event.respond "🚨 **Queue is full! Starting ready check...**"
      event.respond "Type `!ready` within 60 seconds to confirm you're ready to play!"

      mentions = status[:players].map { |p| "<@#{p[:discord_id]}>" }.join(' ')
      event.respond "#{mentions} - Ready check active!"
    end
  end
end

# Start the bot
if __FILE__ == $0
  bot = PugBot.new
  bot.run
end
