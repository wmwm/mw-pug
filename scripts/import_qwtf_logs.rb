#!/usr/bin/env ruby
# Usage: ruby scripts/import_qwtf_logs.rb [max_pages]
# Optionally set env: QWTF_LOGS_MAX_PAGES, QWTF_LOGS_BASE

require_relative '../bot/config/database'
require_relative '../bot/models/player'
require_relative '../bot/services/qwtf_logs_scraper'
require 'logger'
require 'securerandom'

max_pages_arg = ARGV[0]
if max_pages_arg
  ENV['QWTF_LOGS_MAX_PAGES'] = max_pages_arg
end

logger = Logger.new($stdout)
logger.level = Logger::INFO

scraper = QwtfLogsScraper.new(logger: logger)
logger.info "Starting full scrape (max pages=#{ENV['QWTF_LOGS_MAX_PAGES'] || 60})"

matches = scraper.scrape_all(fetch_details: true)
logger.info "Collected #{matches.size} match entries"

aggregate = scraper.build_player_aggregate(matches)
logger.info "Aggregated #{aggregate.size} unique player names"

scraper.persist_players!(aggregate)
logger.info "Player import complete"

scraper.persist_matches!(matches)
logger.info "Match import complete"
