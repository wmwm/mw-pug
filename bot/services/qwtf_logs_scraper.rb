require 'net/http'
require 'nokogiri'
require 'uri'
require 'json'
require 'securerandom'

# QwtfLogsScraper crawls https://logs.qwtf.live/ paginated index and extracts match rows and players.
# It can be run offline (rake task / script) to pre-populate player stats.
class QwtfLogsScraper
  BASE_URL = ENV['QWTF_LOGS_BASE'] || 'https://logs.qwtf.live/'
  MAX_PAGES = (ENV['QWTF_LOGS_MAX_PAGES'] || 60).to_i
  REQUEST_DELAY = (ENV['QWTF_LOGS_DELAY_MS'] || 300).to_i / 1000.0

  MatchEntry = Struct.new(:date, :map, :region_raw, :score_a, :score_b, :team_a_players, :team_b_players, :logs_url, :player_stats, keyword_init: true)

  def initialize(logger: Logger.new($stdout))
    @logger = logger
  end

  def scrape_all(fetch_details: true)
    matches = []
    (1..MAX_PAGES).each do |page|
      page_matches = scrape_page(page)
      break if page_matches.nil? # hard failure
      break if page_matches.empty? # no more pages
      matches.concat(page_matches)
      sleep REQUEST_DELAY if REQUEST_DELAY > 0
    end
    if fetch_details
      enrich_matches_with_details(matches)
    end
    matches
  end

  def build_player_aggregate(matches)
    aggregate = Hash.new { |h,k| h[k] = { name: k, matches: 0, appearances: 0, maps: Hash.new(0), regions: Hash.new(0) } }
    matches.each do |m|
      all_players = m.team_a_players + m.team_b_players
      all_players.each do |p|
        next if p.strip.empty?
        ag = aggregate[p]
        ag[:matches] += 1
        ag[:maps][m.map] += 1 if m.map
        ag[:regions][normalized_region(m.region_raw)] += 1 if m.region_raw
      end
    end
    aggregate
  end

  def persist_players!(aggregate)
    aggregate.each_value do |ag|
      player = Player.find(username: ag[:name]) || Player.find(display_name: ag[:name])
      unless player
        begin
          player = Player.create(
            discord_id: "legacy-#{ag[:name]}-#{SecureRandom.hex(4)}",
            username: ag[:name],
            display_name: ag[:name],
            total_matches: ag[:matches],
            wins: 0,
            losses: 0,
            last_seen: Time.now
          )
        rescue StandardError => e
          @logger.warn "Failed to create player #{ag[:name]}: #{e.message}"
        end
      else
        if ag[:matches] > (player.total_matches || 0)
          player.total_matches = ag[:matches]
          player.save_changes
        end
      end
    end
  end

  # Persist full match records and link players with basic stats.
  def persist_matches!(matches)
    matches.each do |m|
      next unless m.date && m.map
      # Skip if already imported (by logs URL)
      existing = m.logs_url ? Match.first(logs_url: m.logs_url) : nil
      next if existing
      begin
        match_record = Match.create(
          map_name: m.map,
            status: 'completed',
            started_at: Time.parse(m.date) rescue Time.now,
            ended_at: Time.parse(m.date) rescue Time.now,
            region: normalized_region(m.region_raw),
            logs_url: m.logs_url,
            server_id: nil,
            duration_minutes: nil
        )
        # Determine winning team from basic score
        team_a_won = m.score_a.to_i > m.score_b.to_i
        team_b_won = m.score_b.to_i > m.score_a.to_i

        # Player stats hash by name for frags/deaths (if parsed)
        stats_by_name = {}
        if m.player_stats
          m.player_stats.each do |ps|
            stats_by_name[ps[:name]] = ps
          end
        end

        # Insert team A as red, team B as blue
        m.team_a_players.each do |name|
          next if name.to_s.strip.empty?
          player = find_or_stub_player(name)
          next unless player
          ps = stats_by_name[name] || {}
          MatchPlayer.create(
            match_id: match_record.id,
            player_id: player.id,
            team: 'red',
            frags: ps[:frags] || 0,
            deaths: ps[:deaths] || 0,
            won: team_a_won
          )
        end
        m.team_b_players.each do |name|
          next if name.to_s.strip.empty?
          player = find_or_stub_player(name)
          next unless player
          ps = stats_by_name[name] || {}
          MatchPlayer.create(
            match_id: match_record.id,
            player_id: player.id,
            team: 'blue',
            frags: ps[:frags] || 0,
            deaths: ps[:deaths] || 0,
            won: team_b_won
          )
        end
      rescue StandardError => e
        @logger.warn "Failed to persist match entry #{m.logs_url || m.map}: #{e.message}"
      end
    end
  end

  private

  def scrape_page(page)
    url = page == 1 ? BASE_URL : URI.join(BASE_URL, "?page=#{page}").to_s
    @logger.info "Scraping page #{page}: #{url}"
    html = http_get(url)
    return [] unless html
    doc = Nokogiri::HTML(html)
    rows = extract_table_rows(doc)
    rows.map { |r| parse_row(r) }.compact
  rescue StandardError => e
    @logger.error "Failed to scrape page #{page}: #{e.message}"
    []
  end

  def http_get(url)
    uri = URI.parse(url)
    res = Net::HTTP.get_response(uri)
    return res.body if res.is_a?(Net::HTTPSuccess)
    nil
  rescue StandardError => e
    @logger.warn "HTTP error #{url}: #{e.message}"
    nil
  end

  def extract_table_rows(doc)
    # Heuristic: look for table rows with 6 columns (date, map, region, score, teamA, teamB)
    doc.css('table tr').select do |tr|
      cols = tr.css('td')
      cols.length >= 6 && cols[0].text.strip.match(/\d{4}-\d{2}-\d{2}/)
    end
  end

  def parse_row(tr)
    tds = tr.css('td')
    date = tds[0]&.text&.strip
    map = tds[1]&.text&.strip
    region = tds[2]&.text&.strip
    score = tds[3]&.text&.strip
    team_a = tds[4]&.text&.strip.to_s.split(/,\s*/)
    team_b = tds[5]&.text&.strip.to_s.split(/,\s*/)
    score_a, score_b = score.to_s.split(/\s*-\s*/)
    logs_link = extract_logs_link(tr)
    MatchEntry.new(date: date, map: map, region_raw: region, score_a: score_a.to_i, score_b: score_b.to_i, team_a_players: team_a, team_b_players: team_b, logs_url: logs_link, player_stats: nil)
  rescue StandardError => e
    @logger.warn "Row parse failure: #{e.message}"
    nil
  end

  def extract_logs_link(tr)
    # Look for anchor tags referencing /log/ or /logs/
    a = tr.css('a[href*="log"]').first
    return nil unless a
    href = a['href']
    return nil unless href
    URI.join(BASE_URL, href).to_s rescue nil
  end

  def enrich_matches_with_details(matches)
    matches.each do |m|
      next unless m.logs_url
      begin
        html = http_get(m.logs_url)
        next unless html
        doc = Nokogiri::HTML(html)
        m.player_stats = parse_match_detail(doc)
        sleep REQUEST_DELAY if REQUEST_DELAY > 0
      rescue StandardError => e
        @logger.warn "Failed detail fetch #{m.logs_url}: #{e.message}"
      end
    end
  end

  def parse_match_detail(doc)
    # Heuristic extraction: find tables with player rows containing name + frags/deaths columns.
    stats = []
    doc.css('table').each do |table|
      header = table.css('tr').first
      next unless header
      headers = header.css('th,td').map { |h| h.text.strip.downcase }
      name_idx = headers.index { |h| h =~ /player|name/ }
      frags_idx = headers.index { |h| h =~ /frags|kills/ }
      deaths_idx = headers.index { |h| h =~ /deaths/ }
      next unless name_idx
      # Iterate player rows
      table.css('tr')[1..]&.each do |row|
        cells = row.css('td')
        next if cells.empty?
        name = cells[name_idx]&.text&.strip
        next unless name && !name.empty?
        frags_val = frags_idx ? cells[frags_idx]&.text&.strip.to_i : nil
        deaths_val = deaths_idx ? cells[deaths_idx]&.text&.strip.to_i : nil
        stats << { name: name, frags: frags_val, deaths: deaths_val }
      end
      # Accept first plausible table
      break unless stats.empty?
    end
    stats
  end

  def find_or_stub_player(name)
    Player.find(username: name) || Player.find(display_name: name) || begin
      Player.create(
        discord_id: "legacy-#{name}-#{SecureRandom.hex(4)}",
        username: name,
        display_name: name,
        total_matches: 0,
        wins: 0,
        losses: 0,
        last_seen: Time.now
      )
    rescue StandardError => e
      @logger.warn "Failed to create stub player #{name}: #{e.message}"
      nil
    end
  end

  def normalized_region(raw)
    return 'unknown' unless raw
    txt = raw.downcase
    if txt.include?('na') || txt.include?('va') || txt.include?('dallas') || txt.include?('california') || txt.include?('virginia')
      'NA'
    elsif txt.include?('eu') || txt.include?('ireland')
      'EU'
    else
      raw.upcase
    end
  end
end
