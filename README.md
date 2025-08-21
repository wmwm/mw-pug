# Ruby PUG Bot for QuakeWorld Team Fortress

A comprehensive Ruby Discord bot for managing QuakeWorld Team Fortress pickup games (PUGs) with automated AWS server deployment and AI-powered features.

## Features

### 🎮 Core PUG Functionality
- **Queue Management**: 8-player queue with ready check system
- **Automated Matchmaking**: Team balancing and match creation  
- **Server Deployment**: Automatic AWS EC2 FortressOne server deployment
- **Player Statistics**: Comprehensive stats tracking and profiles
- **AI Analysis**: OpenAI-powered gameplay insights and suggestions

### 🌐 Server Management
- **AWS Integration**: Automated EC2 instance management
- **Multi-Region Support**: Sydney (AU) with expansion capability
- **Health Monitoring**: Real-time server status and player count tracking
- **Cost Optimization**: Automatic cleanup of idle servers

### 📊 Player Features
- **Profile System**: Stats, win rates, and performance tracking
- **Match History**: Detailed match records and team compositions
- **Regional Preferences**: Location-based server selection
- **AI Coaching**: Personalized improvement suggestions

## Quick Start

### Prerequisites

- Ruby 3.2.0+
- PostgreSQL 13+
- Discord Bot Application
- AWS Account with EC2 permissions
- OpenAI API key

### Installation

1. **Clone and Install**

   ```bash
   cd ruby-pugbot
   bundle install
   ```


2. **Database Setup**
   ```bash
   ruby config/database.rb
   ```

3. **Environment Configuration**
   ```bash

   cp .env.example .env
   # Edit .env with your credentials
   ```

4. **Run the Bot**
   ```bash
   ruby pugbot.rb
   ```

## Discord Commands

### Player Commands
- `!join` - Join the PUG queue
- `!leave` - Leave the queue  
- `!ready` - Confirm ready for match (during ready check)
- `!status` - View current queue status
- `!profile [@user]` - View player statistics
- `!analyze <query>` - AI-powered gameplay analysis

### Server Commands
- `!startserver [map]` - Deploy FortressOne server
- `!servers` - List active servers
- `!maps` - View available maps

### Admin Commands
- `!reset` - Reset the queue (Admin only)
- `!forcestart` - Force start match with current players (Admin only)

## Architecture

### Database Schema
- **Players**: Discord users with stats and preferences
- **Matches**: Game records with teams and outcomes
- **Servers**: AWS instance tracking and status
- **Queue**: Active queue and ready check management

### Core Services
- **QueueService**: Manages 8-player queue and ready checks
- **AwsService**: Handles EC2 deployment and server lifecycle  
- **AiService**: OpenAI integration for analysis and suggestions
- **Models**: Sequel ORM models for data persistence

### AWS Deployment
- **Instance Type**: t2.micro (free tier compatible)
- **Image**: Ubuntu 22.04 LTS with FortressOne v1.0.4
- **Networking**: Automatic security group and port configuration
- **Monitoring**: HTTP status endpoint on port 28000

## Configuration

### Discord Bot Setup
1. Create application at https://discord.com/developers/applications
2. Generate bot token and client ID
3. Enable "Message Content Intent"
4. Invite to server with appropriate permissions

### AWS Setup  
1. Create IAM user with EC2 permissions
2. Generate access key and secret
3. Configure security groups for ports 27500 (UDP) and 28000 (TCP)

### Database Configuration
The bot uses PostgreSQL with Sequel ORM. Schema is auto-created on first run.

## Deployment Options

### Railway
```json
{
  "build": {
    "builder": "NIXPACKS"  
  },
  "deploy": {
    "startCommand": "bundle exec ruby pugbot.rb"
  }
}
```

### Heroku
```bash
git push heroku main
```

### VPS/Dedicated Server
```bash
# Using systemd service
sudo systemctl enable pugbot
sudo systemctl start pugbot
```

## Integration with Existing Ruby Bots

This bot is designed to integrate seamlessly with existing Ruby Discord bots:

### Shared Database
```ruby
# Use same database connection
require_relative 'path/to/existing/database'
```

### Command Namespacing
```ruby
# Prefix PUG commands to avoid conflicts
@bot.command(:pug_join) { |event| ... }
@bot.command(:pug_status) { |event| ... }
```

### Service Extraction
```ruby
# Use PUG services in existing bot
require_relative 'ruby-pugbot/services/queue_service'
queue = QueueService.instance
```

## Pre-Populating Player Profiles (QWTF Logs Scraper)

To launch with mature player stats, you can scrape historical public match logs from <https://logs.qwtf.live/>.

1. Ensure dependencies are installed (Nokogiri added):

   ```bash
   bundle install
   ```

2. Run the scraper script (optional arg = max pages to crawl):

   ```bash
   ruby scripts/import_qwtf_logs.rb 15
   ```

3. Environment variables (override behavior):

   - `QWTF_LOGS_MAX_PAGES` (default 60)
   - `QWTF_LOGS_BASE` (default <https://logs.qwtf.live/>)
   - `QWTF_LOGS_DELAY_MS` inter-request delay (default 300)

The scraper:

- Crawls paginated index pages and extracts date, map, region, scores, player names.
- Aggregates appearances per player & map counts.
- Creates placeholder player rows (with generated `legacy-*` discord_ids) when no existing Player matches by `username` or `display_name`.
- Updates `total_matches` if scraped appearances exceed stored value.

Linking legacy players: when a real Discord user joins and their username matches a legacy placeholder, you can merge accounts in a future enhancement (not yet automated).


## Contributing

1. Fork the repository
2. Create feature branch
3. Add tests for new functionality  
4. Submit pull request

## License

MIT License - see LICENSE file for details.

## Support

For issues and questions:
- GitHub Issues: Report bugs and feature requests
- Discord: Join development server for real-time support

## Troubleshooting: Render Build Error

If you see this error on Render:

> You are trying to install in deployment mode after changing your Gemfile. Run `bundle install` elsewhere and add the updated Gemfile.lock to version control.

**How to fix:**

1. **On your local machine:**
   - Run:
     ```bash
     bundle install
     ```
   - This will update your `Gemfile.lock` to match your `Gemfile`.

2. **Add and commit the updated lock file:**
   ```bash
   git add Gemfile.lock
   git commit -m "Update Gemfile.lock after Gemfile changes"
   git push
   ```

3. **Redeploy on Render.**

This ensures your `Gemfile.lock` is in sync with your `Gemfile`, which is required for deployment in deployment mode.