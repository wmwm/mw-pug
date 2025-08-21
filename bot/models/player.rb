require_relative '../config/database'

class Player < Sequel::Model
  # Sprint 3: ELO, win streak, MVP
  def elo
    self[:elo] || 1000
  end

  def win_streak
    self[:win_streak] || 0
  end

  def mvp_count
    self[:mvp_count] || 0
  end

  def adjust_elo!(delta)
    self[:elo] = elo + delta
    save_changes
  end

  def increment_win_streak!
    self[:win_streak] = win_streak + 1
    save_changes
  end

  def reset_win_streak!
    self[:win_streak] = 0
    save_changes
  end

  def increment_mvp!
    self[:mvp_count] = mvp_count + 1
    save_changes
  end
  plugin :timestamps, update_on_create: true
  
  one_to_many :match_players
  one_to_many :matches, through: :match_players
  one_to_one :queue_player
  
  def self.find_or_create_by_discord(discord_user)
    player = find(discord_id: discord_user.id.to_s)
    return player if player
    
    create(
      discord_id: discord_user.id.to_s,
      username: discord_user.username,
      display_name: discord_user.display_name || discord_user.username,
      last_seen: Time.now
    )
  end
  
  def update_stats!
    completed_matches = matches.where(status: 'completed')
    self.total_matches = completed_matches.count
    
    match_results = match_players_dataset.join(:matches, id: :match_id)
                                         .where(matches__status: 'completed')
    
    self.wins = match_results.where(won: true).count
    self.losses = match_results.where(won: false).count
    
    avg_frags = match_results.avg(:frags) || 0.0
    self.avg_frags_per_match = avg_frags.round(2)
    
    save_changes
  end
  
  def win_rate
    return 0.0 if total_matches == 0
    (wins.to_f / total_matches * 100).round(1)
  end
  
  def in_queue?
    queue_player && queue_player.status != 'playing'
  end
  
  def playing?
    queue_player && queue_player.status == 'playing'
  end
  
  def profile_summary
    {
      username: username,
      display_name: display_name,
      region: region || 'Unknown',
      total_matches: total_matches,
      wins: wins,
      losses: losses,
      win_rate: "#{win_rate}%",
      avg_frags: avg_frags_per_match,
      elo: elo,
      win_streak: win_streak,
      mvp_count: mvp_count,
      last_seen: last_seen&.strftime('%Y-%m-%d %H:%M UTC')
    }
  end

  def set_country_code(code)
    # Basic validation for 2-letter country code
    if code.to_s.length == 2 && code.to_s.match?(/^[A-Z]{2}$/i)
      self.country_code = code.upcase
      # For now, region is derived from country code. Can be expanded later.
      self.region = code.upcase # Simple mapping for now
      save_changes
      { success: true, message: "Your country code has been set to #{self.country_code}." }
    else
      { success: false, message: "Invalid country code. Please use a 2-letter ISO country code (e.g., AU, US)." }
    end
  end

  def ban!
    self.banned = true
    save_changes
  end

  def unban!
    self.banned = false
    save_changes
  end
end
