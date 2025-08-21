require 'sequel'
require 'dotenv/load'

# Database connection configuration
# Use DATABASE_URL for managed databases (e.g., PostgreSQL on Railway/Heroku).
if ENV['DATABASE_URL']
  DB = Sequel.connect(ENV['DATABASE_URL'])
else
  # For Railway deployment, use in-memory SQLite to avoid filesystem issues
  # For local development, use file-based SQLite
  if ENV['RAILWAY_ENVIRONMENT']
    # Railway deployment - use in-memory database
    puts "Railway environment detected - using in-memory SQLite database"
    DB = Sequel.sqlite # In-memory database
  else
    # Local development - use file-based database
    db_path = File.join('./data', 'pugbot.db')
    # Create data directory if it doesn't exist
    Dir.mkdir('./data') unless Dir.exist?('./data')
    DB = Sequel.sqlite(db_path)
  end
end

# Database schema
DB.create_table? :players do
  primary_key :id
  String :discord_id, unique: true, null: false
  String :username, null: false
  String :display_name
  String :country_code, size: 2
  String :region
  Integer :total_matches, default: 0
  Integer :wins, default: 0
  Integer :losses, default: 0
  Float :avg_frags_per_match, default: 0.0
  DateTime :last_seen
  Boolean :banned, default: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

DB.create_table? :matches do
  primary_key :id
  String :server_id
  String :map_name
  Integer :duration_minutes
  String :status # 'active', 'completed', 'cancelled'
  DateTime :started_at
  DateTime :ended_at
  String :region
  Text :logs_url
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
end

DB.create_table? :match_players do
  primary_key :id
  foreign_key :match_id, :matches, on_delete: :cascade
  foreign_key :player_id, :players, on_delete: :cascade
  String :team # 'red', 'blue'
  Integer :frags, default: 0
  Integer :deaths, default: 0
  Boolean :won, default: false
  DateTime :joined_at, default: Sequel::CURRENT_TIMESTAMP
end

DB.create_table? :queue_players do
  primary_key :id
  foreign_key :player_id, :players, on_delete: :cascade
  String :status # 'queued', 'ready', 'playing'
  DateTime :joined_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :ready_at
  String :preferred_region
end

DB.create_table? :servers do
  primary_key :id
  String :aws_instance_id, unique: true
  String :public_ip
  String :region
  String :status # 'launching', 'running', 'stopping', 'stopped'
  Integer :port, default: 27500
  DateTime :launched_at
  DateTime :last_ping
  Integer :player_count, default: 0
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
end

puts "Database schema initialized successfully"
