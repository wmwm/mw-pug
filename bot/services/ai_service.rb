require 'openai'
require_relative '../models/player'

class AiService
  def initialize
    @client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
  end
  
  def analyze_query(query, discord_user)
    player = Player.find(discord_id: discord_user.id.to_s)
    
    context = build_context(player, query)
    
    response = @client.chat(
      parameters: {
        model: 'gpt-4o',
        messages: [
          {
            role: 'system',
            content: system_prompt
          },
          {
            role: 'user',
            content: "#{context}\n\nQuery: #{query}"
          }
        ],
        max_tokens: 500,
        temperature: 0.7
      }
    )
    
    response.dig('choices', 0, 'message', 'content')
  end
  
  def suggest_map(players)
    player_regions = players.map { |p| p[:player].region }.compact.uniq
    player_count = players.size
    
    prompt = "Suggest a good QuakeWorld Team Fortress map for #{player_count} players from regions: #{player_regions.join(', ')}. Consider balance and fun factor."
    
    response = @client.chat(
      parameters: {
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: 'You are a QuakeWorld Team Fortress expert. Suggest appropriate maps based on player count and regions. Be concise and explain your choice.'
          },
          {
            role: 'user',
            content: prompt
          }
        ],
        max_tokens: 200,
        temperature: 0.3
      }
    )
    
    response.dig('choices', 0, 'message', 'content')
  end
  
  def analyze_match_performance(match)
    match_data = match.match_summary
    
    prompt = <<~PROMPT
      Analyze this QuakeWorld Team Fortress match performance:
      
      Match: #{match_data[:map]} (#{match_data[:duration]} minutes)
      Red Team: #{match_data[:red_team].join(', ')}
      Blue Team: #{match_data[:blue_team].join(', ')}
      
      Provide brief insights on team balance and suggestions for improvement.
    PROMPT
    
    response = @client.chat(
      parameters: {
        model: 'gpt-4o',
        messages: [
          {
            role: 'system',
            content: 'You are a QuakeWorld Team Fortress coach. Analyze matches and provide helpful insights for player improvement.'
          },
          {
            role: 'user',
            content: prompt
          }
        ],
        max_tokens: 400,
        temperature: 0.6
      }
    )
    
    response.dig('choices', 0, 'message', 'content')
  end
  
  private
  
  def build_context(player, query)
    context = "PUG Bot Context:\n"
    
    if player
      profile = player.profile_summary
      context += "Player: #{profile[:display_name]} (#{profile[:region]})\n"
      context += "Stats: #{profile[:total_matches]} matches, #{profile[:win_rate]} win rate\n"
    end
    
    # Add current queue status
    queue_status = QueueService.instance.queue_status
    context += "Current queue: #{queue_status[:size]}/8 players\n"
    
    # Add active servers
    context += "Active servers: #{Server.where(status: 'running').count}\n"
    
    context
  end
  
  def system_prompt
    <<~PROMPT
      You are an AI assistant for a QuakeWorld Team Fortress PUG (Pick-Up Game) Discord bot.
      
      Your role:
      - Help players with QWTF gameplay questions
      - Analyze player statistics and performance
      - Suggest strategies and improvements
      - Provide information about maps, weapons, and tactics
      - Answer questions about the PUG system
      
      Keep responses concise and helpful. Use gaming terminology appropriately.
      Focus on practical advice for competitive QuakeWorld Team Fortress play.
    PROMPT
  end
end
