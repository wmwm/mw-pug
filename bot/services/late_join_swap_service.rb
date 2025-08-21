# Late Join Swap Service for QWTF Parity
class LateJoinSwapService
  def initialize(config)
    @config = config.dig('pug_bot', 'late_join_swap') || {}
    @pending_swaps = []
  end

  def check_late_join(player_id, match_state)
    return false unless @config['enabled']
    
    window_minutes = @config['window_minutes'] || 5
    time_remaining = match_state[:estimated_end] - Time.now
    
    if time_remaining < (window_minutes * 60)
      plan_swap(player_id, match_state)
      true
    else
      false
    end
  end

  def plan_swap(new_player, match_state)
    losing_team = determine_losing_team(match_state)
    swap_candidate = select_swap_candidate(losing_team)
    
    @pending_swaps << {
      new_player: new_player,
      swap_player: swap_candidate,
      timestamp: Time.now
    }
  end

  private

  def determine_losing_team(match_state)
    # Logic to determine losing team
    match_state[:teams].min_by { |team| team[:score] }
  end

  def select_swap_candidate(team)
    # Random selection from losing team
    team[:players].sample
  end
end
