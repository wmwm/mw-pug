
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
require_relative 'services/fortressone_service'
require_relative 'services/location_service'

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
    @fortressone_service = FortressOneService.new
  @location_service = LocationService.new
    # State recovery: reattach if Docker server is running
    if @fortressone_service.running?
      @active_server_instance = { docker: true, status: 'running' }
      @logger.info 'Reattached to running FortressOne Docker server.'
    else
      @active_server_instance = nil # Initialize active server instance
    end

    @map_votes = Hash.new(0) # Initialize map votes

    setup_commands
    setup_events
  end

  def setup_commands
    # Sprint 3: Leaderboard command
    @bot.command(:leaderboard) do |event|
      top_elo = Player.order(Sequel.desc(:elo)).limit(5).all
      top_streak = Player.order(Sequel.desc(:win_streak)).limit(5).all
      top_mvp = Player.order(Sequel.desc(:mvp_count)).limit(5).all
      msg = "🏆 **QWTF Leaderboards**\n"
      msg += "\n**Top ELO:**\n"
      top_elo.each_with_index { |p, i| msg += "#{i+1}. #{p.username} (#{p.elo})\n" }
      msg += "\n**Win Streaks:**\n"
      top_streak.each_with_index { |p, i| msg += "#{i+1}. #{p.username} (#{p.win_streak})\n" }
      msg += "\n**MVPs:**\n"
      top_mvp.each_with_index { |p, i| msg += "#{i+1}. #{p.username} (#{p.mvp_count})\n" }
      event << msg
    end
    # Late join swap logic (Sprint 2)
    @bot.command(:substitute, required_roles: ['Admin', 'Moderator']) do |event, old_mention, new_mention|
      unless old_mention && new_mention
        event << "Usage: !substitute @old @new"
        return
      end
      old_user = event.message.mentions[0]
      new_user = event.message.mentions[1]
      unless old_user && new_user
        event << "Error: Both players must be mentioned."
        return
      end
      old_player = Player.find(discord_id: old_user.id.to_s)
      new_player = Player.find_or_create_by_discord(new_user)
      match = Match.where(status: 'active').order(:started_at).last
      unless old_player && new_player && match
        event << "Error: Players or active match not found."
        return
      end
      mp = match.match_players_dataset.where(player_id: old_player.id).first
      if mp
        mp.player_id = new_player.id
        mp.save_changes
        event << "🔄 Substitution: #{old_player.username} swapped for #{new_player.username}! QWTF-style late join!"
      else
        event << "Error: Old player not in current match."
      end
    end

    # Auto late join swap (if enabled in config, simplified for now)
    @bot.member_join do |event|
      # Only trigger if a match is active and a team is losing (stub logic)
      match = Match.where(status: 'active').order(:started_at).last
      next unless match
      # Find losing team (stub: random for now)
      losing_team = %w[red blue].sample
      # Find a player on losing team to swap out
      mp = match.match_players_dataset.where(team: losing_team).first
      if mp
        new_player = Player.find_or_create_by_discord(event.user)
        mp.player_id = new_player.id
        mp.save_changes
        event.server.general_channel&.send_message("⚡ Late join swap: #{new_player.username} joins #{losing_team.capitalize} team! QWTF-style!")
      end
    end
    # QWTF-style team management commands (admin only)
    @bot.command(:choose, required_roles: ['Admin', 'Moderator']) do |event, player_mention, team|
      unless player_mention && team && %w[red blue].include?(team.downcase)
        event << "Usage: !choose @player red|blue"
        return
      end
      user = event.message.mentions.first
      unless user
        event << "Error: Player not found."
        return
      end
      player = Player.find(discord_id: user.id.to_s)
      match = Match.where(status: 'active').order(:started_at).last
      unless player && match
        event << "Error: Player or active match not found."
        return
      end
      mp = match.match_players_dataset.where(player_id: player.id).first
      if mp
        mp.team = team.downcase
        mp.save_changes
        event << "✅ #{player.username} moved to #{team.capitalize} team."
      else
        event << "Error: Player not in current match."
      end
    end

    @bot.command(:transfer, required_roles: ['Admin', 'Moderator']) do |event, from_mention, to_mention|
      unless from_mention && to_mention
        event << "Usage: !transfer @from @to"
        return
      end
      from_user = event.message.mentions[0]
      to_user = event.message.mentions[1]
      unless from_user && to_user
        event << "Error: Both players must be mentioned."
        return
      end
      from_player = Player.find(discord_id: from_user.id.to_s)
      to_player = Player.find(discord_id: to_user.id.to_s)
      match = Match.where(status: 'active').order(:started_at).last
      unless from_player && to_player && match
        event << "Error: Players or active match not found."
        return
      end
      from_mp = match.match_players_dataset.where(player_id: from_player.id).first
      to_mp = match.match_players_dataset.where(player_id: to_player.id).first
      if from_mp && to_mp
        temp_team = from_mp.team
        from_mp.team = to_mp.team
        to_mp.team = temp_team
        from_mp.save_changes
        to_mp.save_changes
        event << "🔄 Swapped teams: #{from_player.username} <-> #{to_player.username}"
      else
        event << "Error: Both players must be in the current match."
      end
    end

    @bot.command(:merge, required_roles: ['Admin', 'Moderator']) do |event, team|
      unless team && %w[red blue].include?(team.downcase)
        event << "Usage: !merge red|blue"
        return
      end
      match = Match.where(status: 'active').order(:started_at).last
      unless match
        event << "Error: No active match found."
        return
      end
      # Move all players to the specified team
      match.match_players_dataset.each do |mp|
        mp.team = team.downcase
        mp.save_changes
      end
      event << "All players merged to #{team.capitalize} team. QWTF-style chaos!"
    end
    # Map voting command
    @bot.command(:map) do |event, *args|
      map_name = args.first&.downcase
      valid_maps = %w[2fort5r well6 canalzon openfire rock1 dm4]
      unless map_name && valid_maps.include?(map_name)
        event << "❌ Invalid or missing map name. Available: #{valid_maps.join(', ')}"
        return
      end
      @map_votes[map_name] += 1
      event << "🗳️ Vote registered for **#{map_name}**! Current votes: #{@map_votes[map_name]}"
      event << "QWTF classic! Map voting is open until all players are ready. Use `!map <name>` to vote."
    end
    # Queue management commands
    @bot.command(:join) do |event|
      result = @queue_service.add_player(event.user)

      # Auto-detect location if not set
      if result[:success]
        player = Player.find(discord_id: event.user.id.to_s)
        if player && (player.country_code.nil? || player.country_code.strip.empty?)
          detected = @location_service.detect(player)
          if detected
            player.country_code = detected
            player.region = detected
            player.save_changes
            event << "🌍 Detected location: #{detected}"
          end
        end
      end

      if result[:success]
        event << "✅ #{result[:message]}"

        # Send queue status
        status = @queue_service.queue_status
        if status[:size] > 0
          queue_list = status[:players].map.with_index(1) do |p, i|
            "#{i}. #{p[:display_name]} (#{p[:region]}) - #{p[:time_waiting]}"
          end.join("\n")
          event << "📋 **Current Queue (#{status[:size]}/#{status[:max_size]}):**\n#{queue_list}"
        end

        # QWTF nostalgia: If queue is empty or just started
        if status[:size] == 1
          event << "🕹️ Waiting for legends to join! Invite your clanmates for a classic QWTF PUG."
        elsif status[:size] == MAX_QUEUE_SIZE - 1
          event << "⚡ One more needed for a full game! Who will step up for glory?"
        end

        # Check if ready check should start
        if status[:size] >= MAX_QUEUE_SIZE
          event << "🚨 **Queue is full! Starting ready check...**"
          event << "Type `!ready` within 60 seconds to confirm you're ready to play!"
          # Mention all queued players
          mentions = status[:players].map { |p| "<@#{p[:discord_id]}>" }.join(' ')
          event << "#{mentions} - Ready check active!"
        end
      else
        event << "❌ #{result[:message]}"
      end
    end

    @bot.command(:leave) do |event|
      result = @queue_service.remove_player(event.user)
      if result[:success]
        event << "👋 #{result[:message]}"
        status = @queue_service.queue_status
        if status[:size] == 0
          event << "Queue is now empty. Waiting for the next wave of QWTF heroes!"
        elsif status[:size] == 1
          event << "Only one player left in queue. Rally your friends for a classic match!"
        end
      else
        event << "❌ #{result[:message]}"
      end
    end

    @bot.command(:ready) do |event|
      result = @queue_service.player_ready(event.user)

      if result[:success]
        event << "🟢 #{result[:message]}"

        # Check if match should start
        ready_status = @queue_service.ready_status
        if ready_status && ready_status[:ready_count] >= MAX_QUEUE_SIZE
          event << "🎮 **All players ready! Creating match...**"
          start_match(event)
        elsif ready_status
          remaining = MAX_QUEUE_SIZE - ready_status[:ready_count]
          event << "⏳ Waiting for #{remaining} more to ready up. Legends assemble!"
        end
      else
        event << "❌ #{result[:message]}"
      end
    end

    @bot.command(:unready) do |event|
      result = @queue_service.player_unready(event.user)
      if result[:success]
        event << "🟡 #{result[:message]}"
      else
        event << "❌ #{result[:message]}"
      end
    end

    @bot.command(:status) do |event|
      status = @queue_service.queue_status

      if status[:size] == 0
        event << "📋 **Queue is empty.** Type `!join` to start a game!"
        event << "QWTF PUGs are legendary—invite your friends and relive the glory!"
      else
        queue_list = status[:players].map.with_index(1) do |p, i|
          "#{i}. #{p[:display_name]} (#{p[:region]}) - #{p[:time_waiting]}"
        end.join("\n")

        embed = Discordrb::Webhooks::Embed.new(
          title: "Status: PUG Queue Status",
          description: "**Current Queue (#{status[:size]}/#{status[:max_size]}):**\n#{queue_list}",
          color: status[:size] >= MAX_QUEUE_SIZE ? 0x00ff00 : 0xffa500,
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
      end
    end

    # Server management commands  
    @bot.command(:startserver) do |event, map_name = '2fort'|
      if @active_server_instance
        event << "A FortressOne server is already running and attached to the bot."
        return
      end

      event << "🚀 **Starting FortressOne server (Docker Compose)...**"
      event << "Map: #{map_name}"
      # Optionally: region selection, more args

      result = @fortressone_service.start_server(map: map_name)

      if result[:success]
        @active_server_instance = { docker: true, status: 'starting' }
        event << "✅ **FortressOne server deployment initiated!**"
        event << "Use `!serverstatus` to check status."
      else
        event << "❌ **Failed to start FortressOne server:** #{result[:stderr]}"
      end
    end

    @bot.command(:restartserver, required_roles: ['Admin']) do |event|
      if @active_server_instance && @active_server_instance[:docker]
        result = @fortressone_service.restart_server
        if result[:success]
          event << "🔄 **FortressOne Docker server restarted.**"
        else
          event << "❌ Failed to restart FortressOne server: #{result[:stderr]}"
        end
      else
        event << "No FortressOne Docker server is currently attached."
      end
    end

    @bot.command(:serverlogs, required_roles: ['Admin']) do |event, tail = '100'|
      if @active_server_instance && @active_server_instance[:docker]
        result = @fortressone_service.logs(tail: tail.to_i)
        if result[:success]
          log_block = "📜 **FortressOne Server Logs (last #{tail} lines):**\n```\n#{result[:stdout][0..1800]}\n```"
          event << log_block
        else
          event << "❌ Failed to fetch logs: #{result[:stderr]}"
        end
      else
        event << "No FortressOne Docker server is currently attached."
      end
    end

    @bot.command(:reloadserver, required_roles: ['Admin']) do |event|
      if @active_server_instance && @active_server_instance[:docker]
        result = @fortressone_service.reload_config
        if result[:success]
          event << "♻️ **FortressOne server config reloaded (SIGHUP sent).**"
        else
          event << "❌ Failed to reload config: #{result[:stderr]}"
        end
      else
        event << "No FortressOne Docker server is currently attached."
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
      if @active_server_instance && @active_server_instance[:docker]
        status = @fortressone_service.server_status
        if status[:success]
          event << "🖥️ **FortressOne Docker Server Status:**\n#{status[:stdout]}"
        else
          event << "❌ Failed to get FortressOne server status: #{status[:stderr]}"
        end
      else
        event << "No FortressOne Docker server is currently attached."
      end
    end

    @bot.command(:stopserver) do |event|
      if @active_server_instance && @active_server_instance[:docker]
        result = @fortressone_service.stop_server
        if result[:success]
          @active_server_instance = nil
          event << "🛑 **FortressOne Docker server stopped and detached.**"
        else
          event << "❌ Failed to stop FortressOne server: #{result[:stderr]}"
        end
      else
        event << "No FortressOne Docker server is currently attached."
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

    @bot.command(:setlocation, required_roles: ['Admin', 'Moderator']) do |event, country_code|
      unless country_code
        event << "Admin: Provide a 2-letter country code (e.g., AU, US)."
        next
      end
      player = Player.find_or_create_by_discord(event.user)
      result = player.set_country_code(country_code)
      event << "(Admin override) #{result[:message]}"
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
      # Match legacy style of existing production bot: simple flat list
      legacy_commands = %w[
        help join leave queue requeue team status start choose map server end notify voice force_restart transfer instances up down instance maps league_elos show set merge psyncroles
      ]
      event << "List of commands:\n" + legacy_commands.join(', ')
    end

    # --- Command Aliases / Legacy Compatibility Layer ---
    # These lightweight aliases mimic the older bot's command names so users get expected behavior.

    # !queue -> same as !status (show queue)
    @bot.command(:queue) { |event| @bot.execute_command(:status, event) }

    # !requeue -> leave then join (resets position/time)
    @bot.command(:requeue) do |event|
      @queue_service.remove_player(event.user)
      result = @queue_service.add_player(event.user)
      if result[:success]
        event << "🔄 Re-queued. #{result[:message]}"
      else
        event << "❌ #{result[:message]}"
      end
    end

    # !start -> alias of !startserver (map optional)
    @bot.command(:start) do |event, map_name = '2fort'|
      @bot.execute_command(:startserver, event, map_name)
    end

    # !server -> consolidated quick status summary
    @bot.command(:server) do |event|
      if @active_server_instance && @active_server_instance[:docker]
        status = @fortressone_service.server_status
        if status[:success]
          event << "Server status:\n" + status[:stdout]
        else
          event << "❌ #{status[:stderr]}"
        end
      else
        event << "No attached FortressOne Docker server. Use !start (alias for !startserver)."
      end
    end

    # !force_restart -> alias for restartserver (admin)
    @bot.command(:force_restart, required_roles: ['Admin', 'Moderator']) do |event|
      @bot.execute_command(:restartserver, event)
    end

    # !team -> show teams of active match
    @bot.command(:team) do |event|
      match = Match.where(status: 'active').order(:started_at).last
      unless match
        event << "No active match."
        next
      end
      red = match.red_team.map(&:username).join(', ')
      blue = match.blue_team.map(&:username).join(', ')
      event << "Teams:\n🔴 Red: #{red.empty? ? 'None' : red}\n🔵 Blue: #{blue.empty? ? 'None' : blue}"
    end

    # Placeholder / stub commands that exist in legacy bot but not yet implemented here
    %i[end notify voice instances up down instance maps league_elos show set psyncroles].each do |cmd|
      @bot.command(cmd) do |event, *args|
        event << "(#{cmd}) feature not implemented yet in this rewrite."
      end
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
      player = Player.find_or_create_by_discord(event.user)

      # Attempt auto-detect of location on join if missing
      if player && (player.country_code.nil? || player.country_code.strip.empty?)
        detected = @location_service.detect(player)
        if detected
          player.country_code = detected
          player.region = detected
          player.save_changes
          @logger.info "Auto-detected location #{detected} for #{player.username} on member join"
        end
      end

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
      # Sprint 4: Voice channel auto-move for teams
      begin
        guild = event.server
        red_channel = guild.voice_channels.find { |c| c.name == 'QWTF Red' } || guild.create_channel('QWTF Red', 2)
        blue_channel = guild.voice_channels.find { |c| c.name == 'QWTF Blue' } || guild.create_channel('QWTF Blue', 2)
        match.red_team.each do |player|
          member = guild.members.find { |m| m.username == player.username }
          member&.move_to(red_channel)
        end
        match.blue_team.each do |player|
          member = guild.members.find { |m| m.username == player.username }
          member&.move_to(blue_channel)
        end
        event.channel.send_message("🔊 Teams have been moved to their QWTF voice channels! Red and Blue, report in!")
      rescue => e
        @logger.warn "Voice channel move failed: #{e.inspect}"
      end
    # Sprint 4: Notification preference stub
    @bot.command(:notify_pref) do |event, pref|
      # Placeholder for notification preference logic
      event << "Notification preferences coming soon! (Sprint 4)"
    end
    begin
      # Get match data from queue
      match_data = force ? @queue_service.force_create_match : @queue_service.get_ready_match
      return event << "Error: **No match ready to start.**" unless match_data

      # Determine map to use
      chosen_map = nil
      if @map_votes.any?
        max_votes = @map_votes.values.max
        top_maps = @map_votes.select { |_, v| v == max_votes }.keys
        chosen_map = top_maps.sample # random among tied
      end
      valid_maps = %w[2fort5r well6 canalzon openfire rock1 dm4]
      chosen_map ||= (valid_maps & @map_votes.keys).first || valid_maps.sample

      # Start server with chosen map
      server_result = @aws_service.deploy_server(match_data[:region], chosen_map)
      unless server_result[:success]
        event << "Error: **Failed to start server:** #{server_result[:error]}"
        return
      end

      # Create match record
      match = Match.create_new_match(
        server_result[:instance_id],
        chosen_map,
        match_data[:region]
      )
      match.add_players(match_data[:players].map { |p| p[:player] })

      # Announce match with QWTF nostalgia
      embed = Discordrb::Webhooks::Embed.new(
        title: "🎮 QWTF Match Started!",
        description: "Server is starting up... Prepare for battle on **#{chosen_map}**!",
        color: 0x00ff00,
        timestamp: Time.now
      )
      red_team = match.red_team.map(&:username).join(', ')
      blue_team = match.blue_team.map(&:username).join(', ')
      embed.add_field(name: "🔴 Red Team", value: red_team, inline: false)
      embed.add_field(name: "🔵 Blue Team", value: blue_team, inline: false)
      embed.add_field(name: "🗺️ Map", value: chosen_map, inline: true)
      embed.add_field(name: "🌍 Region", value: match_data[:region], inline: true)
      embed.add_field(name: "⏳ Status", value: "Server starting...", inline: true)
      event.channel.send_embed('', embed)

      # Mention all players
      mentions = match_data[:players].map { |p| "<@#{p[:discord_user].id}>" }.join(' ')
      event << "#{mentions} - Your QWTF match is starting on **#{chosen_map}**! Server details soon."

      # Reset map votes for next match
      @map_votes.clear
  # Store match/channel for recap
  @last_match = match
  @last_match_channel = event.channel
    rescue => e
      @logger.error "Failed to start match: #{e.inspect}"
      event << "Error: **Failed to start match:** #{e.message}"
    end
  end
  
  def run
    # Hook for match recap after match ends (Sprint 2)
    Thread.new do
      loop do
        sleep(10)
        if @last_match && @last_match.status == 'completed'
          recap = "🏆 **Match Recap**\nMap: #{@last_match.map_name}\nRegion: #{@last_match.region}\nDuration: #{@last_match.duration_minutes} min\n"
          recap += "🔴 Red: #{@last_match.red_team.map(&:username).join(', ')}\n"
          recap += "🔵 Blue: #{@last_match.blue_team.map(&:username).join(', ')}\n"
          recap += "GGs all! Use !profile to see your stats."
          @last_match_channel&.send_message(recap)
          @last_match = nil
          @last_match_channel = nil
        end
      end
    end
    @bot.run
  end
end

# Start the bot
if __FILE__ == $0
  bot = PugBot.new

  bot.run
end
