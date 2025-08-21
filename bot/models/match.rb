require_relative '../config/database'

class Match < Sequel::Model
  plugin :timestamps, update_on_create: true
  
  one_to_many :match_players
  many_to_many :players, through: :match_players
  many_to_one :server
  
  def self.create_new_match(server_id, map_name, region = 'Sydney')
    create(
      server_id: server_id,
      map_name: map_name,
      region: region,
      status: 'active',
      started_at: Time.now
    )
  end
  
  def add_players(players_array)
    # Sprint 2: Auto-balance teams by ELO if available, else random
    players = players_array.shuffle
    if players.first.respond_to?(:elo)
      sorted = players.sort_by { |p| -(p.elo || 1000) }
      red, blue = [], []
      sorted.each_with_index do |p, i|
        (red.sum { |pl| pl.elo || 1000 } <= blue.sum { |pl| pl.elo || 1000 } ? red : blue) << p
      end
      red.each { |player| add_match_player(player_id: player.id, team: 'red', joined_at: Time.now) }
      blue.each { |player| add_match_player(player_id: player.id, team: 'blue', joined_at: Time.now) }
    else
      players.each_with_index do |player, index|
        team = index < 4 ? 'red' : 'blue'
        add_match_player(player_id: player.id, team: team, joined_at: Time.now)
      end
    end
  end
  
  def red_team
    players.join(:match_players, player_id: :id)
           .where(match_players__team: 'red')
  end
  
  def blue_team
    players.join(:match_players, player_id: :id)
           .where(match_players__team: 'blue')
  end
  
  def complete_match!
  self.status = 'completed'
  self.ended_at = Time.now
  self.duration_minutes = ((ended_at - started_at) / 60).round
  save_changes
  # Update player statistics
      # Sprint 3: ELO, win streak, MVP
      # Calculate MVP (most frags)
      mvp_mp = match_players_dataset.max_by { |mp| mp.frags || 0 }
      mvp_player = mvp_mp && Player[ mvp_mp.player_id ]
      mvp_player&.increment_mvp!
      # Adjust ELO and win streaks
      red_score = match_players_dataset.where(team: 'red').sum(:frags) || 0
      blue_score = match_players_dataset.where(team: 'blue').sum(:frags) || 0
      winner_team = red_score > blue_score ? 'red' : (blue_score > red_score ? 'blue' : nil)
      match_players_dataset.each do |mp|
        player = Player[mp.player_id]
        if winner_team && mp.team == winner_team
          player.adjust_elo!(+15)
          player.increment_win_streak!
        else
          player.adjust_elo!(-10)
          player.reset_win_streak!
        end
        player.update_stats!
      end
      # QWTF-style match recap (Sprint 2+3)
      recap = "🏆 **Match Recap**\nMap: #{map_name}\nRegion: #{region}\nDuration: #{duration_minutes} min\n"
      recap += "🔴 Red: #{red_team.map(&:username).join(', ')} (#{red_score})\n"
      recap += "🔵 Blue: #{blue_team.map(&:username).join(', ')} (#{blue_score})\n"
      recap += "🏅 MVP: #{mvp_player&.username || 'N/A'}\n"
      recap += "GGs all! Use !profile to see your stats."
      Discordrb::LOGGER.info recap
  end
  
  def cancel_match!
    self.status = 'cancelled'
    self.ended_at = Time.now
    save_changes
  end
  
  def match_summary
    {
      id: id,
      server_id: server_id,
      map: map_name,
      region: region,
      status: status,
      duration: duration_minutes || 0,
      started_at: started_at&.strftime('%Y-%m-%d %H:%M UTC'),
      red_team: red_team.map(&:username),
      blue_team: blue_team.map(&:username),
      logs_url: logs_url
    }
  end
end
