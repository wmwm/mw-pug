require 'net/http'
require 'json'
require 'uri'

# LocationService auto-detects player country/region from a live QWTF stats endpoint.
# Expected endpoint response formats (examples):
# 1) { "players": [ { "name": "Player1", "country": "AU" }, ... ] }
# 2) [ { "name": "Player1", "country": "AU" }, ... ]
# Country is expected to be a 2-letter ISO code; service normalizes value.
class LocationService
  CACHE_TTL = 300 # seconds

  def initialize(endpoint = ENV['QWTF_STATS_ENDPOINT'])
    @endpoint = endpoint
    @cache = nil
    @fetched_at = nil
  end

  # Attempt to detect a player's country code based on username/display_name.
  # Returns 2-letter code or nil if undetectable.
  def detect(player)
    return nil unless @endpoint
    data = fetch_data
    return nil if data.empty?

    name_candidates = [player.username, player.display_name].compact.map(&:downcase).uniq
    match = data.find do |entry|
      entry_name = (entry['name'] || entry[:name]).to_s.downcase
      name_candidates.include?(entry_name)
    end

    return nil unless match
    raw_country = match['country'] || match[:country] || match['cc'] || match[:cc]
    normalize_country(raw_country)
  rescue StandardError
    nil
  end

  private

  def fetch_data
    if @cache && @fetched_at && (Time.now - @fetched_at) < CACHE_TTL
      return @cache
    end
    @cache = []
    return @cache unless @endpoint

    uri = URI.parse(@endpoint)
    response = Net::HTTP.get_response(uri)
    if response.code.to_i == 200
      begin
        json = JSON.parse(response.body)
        players = if json.is_a?(Hash) && json['players'].is_a?(Array)
                    json['players']
                  elsif json.is_a?(Array)
                    json
                  else
                    []
                  end
        @cache = players
        @fetched_at = Time.now
      rescue JSON::ParserError
        # leave cache empty
      end
    end
    @cache
  rescue StandardError
    @cache || []
  end

  def normalize_country(code)
    return nil unless code
    c = code.to_s.strip.upcase
    return nil unless c.match?(/^[A-Z]{2}$/)
    c
  end
end
