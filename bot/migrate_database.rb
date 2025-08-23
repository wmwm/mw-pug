#!/usr/bin/env ruby

require_relative 'config/database'

# Run migrations if needed
puts "Checking for database migrations..."
DB.tables # This will initialize the DB connection

# Create tables if they don't exist
unless DB.table_exists?(:players)
  puts "Creating players table..."
  DB.create_table :players do
    primary_key :id
    String :discord_id, null: false, unique: true
    String :username, null: false
    String :discriminator
    String :region
    String :country_code
    Integer :elo, default: 1500
    Integer :wins, default: 0
    Integer :losses, default: 0
    Integer :win_streak, default: 0
    Integer :lose_streak, default: 0
    Integer :mvp_count, default: 0
    Boolean :is_banned, default: false
    DateTime :last_seen
    DateTime :created_at
    DateTime :updated_at
  end
  puts "Players table created"
end

unless DB.table_exists?(:matches)
  puts "Creating matches table..."
  DB.create_table :matches do
    primary_key :id
    String :instance_id
    String :status, default: 'active' # active, completed, cancelled
    String :region
    String :map_name
    Float :average_elo
    DateTime :started_at
    DateTime :ended_at
  end
  puts "Matches table created"
end

unless DB.table_exists?(:match_players)
  puts "Creating match_players table..."
  DB.create_table :match_players do
    primary_key :id
    foreign_key :match_id, :matches
    foreign_key :player_id, :players
    String :team # 'red' or 'blue'
    Integer :frags, default: 0
    Integer :deaths, default: 0
    Boolean :mvp, default: false
    DateTime :joined_at
    DateTime :left_at
  end
  puts "Match players table created"
end

puts "Database schema initialized successfully"
