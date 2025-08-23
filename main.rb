#!/usr/bin/env ruby

# This is the main entry point for the bot

# First check if we need to run database migrations
require_relative 'bot/migrate_database'

# Now load the main bot
require_relative 'bot/pugbot'

# Start the bot
if __FILE__ == $0
  bot = PugBot.new
  bot.run
end
