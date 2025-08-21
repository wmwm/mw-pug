#!/usr/bin/env ruby

require 'discordrb'
require 'dotenv/load'
require 'logger'

class SimplePugBot
  MAX_QUEUE_SIZE = 8

  def initialize
    # Check for required environment variables
    token = ENV['DISCORD_PUG_BOT_TOKEN']
    client_id = ENV['DISCORD_PUG_CLIENT_ID']
    
    if token.nil? || token.empty?
      puts "❌ ERROR: DISCORD_PUG_BOT_TOKEN not found in .env file"
      puts "Please add your Discord bot token to the .env file:"
      puts "DISCORD_PUG_BOT_TOKEN=your_bot_token_here"
      exit(1)
    end

    if client_id.nil? || client_id.empty?
      puts "⚠️  WARNING: DISCORD_PUG_CLIENT_ID not found in .env file"
      puts "Some features may not work properly without the client ID"
    end

    @bot = Discordrb::Commands::CommandBot.new(
      token: token,
      client_id: client_id,
      prefix: '!',
      advanced_functionality: true
    )

    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO

    @queue = []
    @ready_players = []

    setup_commands
    setup_events
  end

  def setup_commands
    # Queue management commands
    @bot.command([:join, '++']) do |event|
      user = event.user
      
      if @queue.any? { |p| p[:id] == user.id }
        event.respond("❌ You're already in the queue!", ephemeral: true)
        next
      end

      @queue << {
        id: user.id,
        username: user.username,
        display_name: user.display_name
      }

      event.message.delete rescue nil
      show_queue_status(event)
    end

    @bot.command([:leave, '--']) do |event|
      user = event.user
      
      @queue.reject! { |p| p[:id] == user.id }
      @ready_players.reject! { |p| p[:id] == user.id }

      event.message.delete rescue nil
      show_queue_status(event)
    end

    @bot.command(:status) do |event|
      event.message.delete rescue nil
      show_queue_status(event)
    end

    @bot.command(:ready) do |event|
      user = event.user
      
      unless @queue.any? { |p| p[:id] == user.id }
        event.respond("❌ You must be in the queue first!", ephemeral: true)
        next
      end

      if @ready_players.any? { |p| p[:id] == user.id }
        event.respond("✅ You're already ready!", ephemeral: true)
        next
      end

      @ready_players << {
        id: user.id,
        username: user.username,
        display_name: user.display_name
      }

      event.respond("✅ You are ready to play!", ephemeral: true)

      if @ready_players.length >= MAX_QUEUE_SIZE
        event.respond("🎮 **All players ready! Starting match...**")
        start_match(event)
      else
        remaining = MAX_QUEUE_SIZE - @ready_players.length
        event.respond("⏳ Waiting for #{remaining} more players to ready up...")
      end
    end

    @bot.command(:unready) do |event|
      user = event.user
      @ready_players.reject! { |p| p[:id] == user.id }
      event.respond("❌ You are no longer ready.", ephemeral: true)
    end

    @bot.command(:help) do |event|
      commands = ['help', 'join', 'leave', 'status', 'ready', 'unready', 'reset']
      command_list = commands.map { |c| "`#{c}`" }.join(', ')
      response = "**List of commands:**\n#{command_list}"
      event.respond(response)
    end

    # Admin commands
    @bot.command(:reset) do |event|
      @queue.clear
      @ready_players.clear
      event.respond("✅ **Queue has been reset.**")
    end
  end

  def setup_events
    @bot.ready do |event|
      @logger.info "Simple PUG Bot Ready! Logged in as #{@bot.profile.username}"
      @logger.info "Bot is running in #{@bot.servers.count} servers"

      @bot.servers.each do |id, server|
        @logger.info "Connected to server: #{server.name} (ID: #{id})"
        
        # Find #pugbot channel and announce readiness
        pugbot_channel = server.channels.find { |c| c.name == 'pugbot' }
        if pugbot_channel
          @logger.info "Found #pugbot channel in #{server.name}"
          pugbot_channel.send_message("🤖 **Simple PUG Bot is online!**\nType `!join` or `++` to start playing!")
        end
      end

      # Set bot activity
      @bot.game = "Type !join to play | 0/8 in queue"
    end

    # Update bot activity every 30 seconds
    Thread.new do
      loop do
        sleep(30)
        begin
          @bot.game = "Type !join to play | #{@queue.length}/8 in queue"
        rescue StandardError => e
          @logger.error "Failed to update bot activity: #{e.inspect}"
        end
      end
    end
  end

  def start_match(event)
    begin
      # Simple match creation
      teams = @ready_players.shuffle

      red_team = teams[0, 4]
      blue_team = teams[4, 4]

      embed = Discordrb::Webhooks::Embed.new(
        title: "🎮 Match Started!",
        description: "Get ready to play!",
        color: 0x00ff00,
        timestamp: Time.now
      )

      red_names = red_team.map { |p| p[:display_name] }.join(', ')
      blue_names = blue_team.map { |p| p[:display_name] }.join(', ')

      embed.add_field(name: "🔴 Red Team", value: red_names, inline: false)
      embed.add_field(name: "🔵 Blue Team", value: blue_names, inline: false)
      embed.add_field(name: "🗺️ Map", value: "dm4", inline: true)

      event.channel.send_embed('', embed)

      # Mention all players
      mentions = @ready_players.map { |p| "<@#{p[:id]}>" }.join(' ')
      event.respond("#{mentions} - Your match is starting!")

      # Reset the queue and ready players
      @queue.clear
      @ready_players.clear

    rescue => e
      @logger.error "Failed to start match: #{e.inspect}"
      event.respond("❌ **Failed to start match:** #{e.message}")
    end
  end

  def show_queue_status(event)
    if @queue.empty?
      description = "The queue is empty! Type `!join` or `++` to get started."
    else
      player_list = @queue.map.with_index(1) do |p, i|
        "#{i}. `#{p[:display_name]}`"
      end.join("\n")
      description = "**Players in queue (#{@queue.length}/#{MAX_QUEUE_SIZE}):**\n#{player_list}"
    end

    embed = Discordrb::Webhooks::Embed.new(
      title: "Oceania - FortressOne PUG",
      description: description,
      color: 0x0099ff,
      timestamp: Time.now
    )

    if @queue.length >= MAX_QUEUE_SIZE && @ready_players.length < MAX_QUEUE_SIZE
      embed.add_field(
        name: "🚨 Ready Check Active",
        value: "Ready: #{@ready_players.length}/#{MAX_QUEUE_SIZE}\nType `!ready` to confirm you're ready to play!",
        inline: false
      )
    end

    event.channel.send_embed('', embed)

    # Start ready check if queue is full
    if @queue.length >= MAX_QUEUE_SIZE && @ready_players.length == 0
      event.respond("🚨 **Queue is full! Starting ready check...**")
      event.respond("Type `!ready` within 60 seconds to confirm you're ready to play!")
      
      mentions = @queue.map { |p| "<@#{p[:id]}>" }.join(' ')
      event.respond("#{mentions} - Ready check active!")
    end
  end

  def run
    @bot.run
  end
end

# Start the bot
if __FILE__ == $0
  bot = SimplePugBot.new
  bot.run
end
