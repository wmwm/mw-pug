#!/usr/bin/env ruby

# This script checks if the repository is properly set up for Railway deployment
# by validating configuration files and dependencies

require 'json'
require 'yaml'
require 'fileutils'

class DeploymentChecker
  REQUIRED_FILES = [
    'railway.json',
    'Procfile',
    'nixpacks.toml',
    'Gemfile',
    'Gemfile.lock',
    'bot/pugbot.rb'
  ]
  
  def initialize
    @issues = []
    @warnings = []
  end
  
  def check_required_files
    puts "Checking required files..."
    REQUIRED_FILES.each do |file|
      if File.exist?(file)
        puts "✓ #{file} exists"
      else
        @issues << "Missing required file: #{file}"
        puts "✗ #{file} is missing"
      end
    end
    puts
  end
  
  def check_railway_json
    puts "Checking railway.json configuration..."
    begin
      if File.exist?('railway.json')
        railway_config = JSON.parse(File.read('railway.json'))
        
        # Check start command
        if railway_config.dig('deploy', 'startCommand') == 'bundle exec ruby bot/pugbot.rb'
          puts "✓ Railway start command is correct"
        else
          @issues << "Incorrect startCommand in railway.json. Should be 'bundle exec ruby bot/pugbot.rb'"
          puts "✗ Railway start command is incorrect"
        end
      end
    rescue JSON::ParserError => e
      @issues << "railway.json is not valid JSON: #{e.message}"
      puts "✗ railway.json is not valid JSON"
    end
    puts
  end
  
  def check_procfile
    puts "Checking Procfile configuration..."
    if File.exist?('Procfile')
      procfile_content = File.read('Procfile').strip
      if procfile_content == "worker: bundle exec ruby bot/pugbot.rb"
        puts "✓ Procfile has correct worker command"
      else
        @issues << "Incorrect worker command in Procfile. Should be 'worker: bundle exec ruby bot/pugbot.rb'"
        puts "✗ Procfile has incorrect worker command"
      end
    end
    puts
  end
  
  def check_nixpacks
    puts "Checking nixpacks.toml configuration..."
    if File.exist?('nixpacks.toml')
      nixpacks_content = File.read('nixpacks.toml')
      if nixpacks_content.include?('cmd = "bundle exec ruby bot/pugbot.rb"')
        puts "✓ nixpacks.toml has correct start command"
      else
        @issues << "Incorrect start command in nixpacks.toml. Should include 'cmd = \"bundle exec ruby bot/pugbot.rb\"'"
        puts "✗ nixpacks.toml has incorrect start command"
      end
    end
    puts
  end
  
  def check_env_file
    puts "Checking environment configuration..."
    if File.exist?('.env.example')
      example_env = File.read('.env.example')
      if example_env.include?('DISCORD_PUG_BOT_TOKEN')
        puts "✓ .env.example includes Discord token configuration"
      else
        @warnings << "No Discord token configuration found in .env.example"
        puts "⚠ No Discord token configuration found in .env.example"
      end
    else
      @warnings << "No .env.example file found"
      puts "⚠ No .env.example file found"
    end
    puts
  end
  
  def check_github_workflow
    puts "Checking GitHub Actions workflow..."
    workflow_path = '.github/workflows/railway_deployment.yml'
    
    if File.exist?(workflow_path)
      workflow_content = File.read(workflow_path)
      if workflow_content.include?('Deploy to Railway')
        puts "✓ GitHub workflow for Railway deployment exists"
      else
        @warnings << "GitHub workflow may not be configured for Railway deployment"
        puts "⚠ GitHub workflow may not be configured for Railway deployment"
      end
    else
      @warnings << "No GitHub workflow for Railway deployment found"
      puts "⚠ No GitHub workflow for Railway deployment found"
    end
    puts
  end
  
  def run_checks
    puts "======= Railway Deployment Check ======="
    puts
    
    check_required_files
    check_railway_json
    check_procfile
    check_nixpacks
    check_env_file
    check_github_workflow
    
    puts "======= Summary ======="
    if @issues.empty?
      puts "✅ No critical issues found. Your app should deploy correctly."
    else
      puts "❌ #{@issues.size} critical issue(s) found that may prevent successful deployment:"
      @issues.each do |issue|
        puts "  - #{issue}"
      end
    end
    
    unless @warnings.empty?
      puts
      puts "⚠️ #{@warnings.size} warning(s) found:"
      @warnings.each do |warning|
        puts "  - #{warning}"
      end
    end
    
    puts
    puts "Run this script again after addressing any issues."
    puts "===============================\n\n"
    
    exit(@issues.empty? ? 0 : 1)
  end
end

checker = DeploymentChecker.new
checker.run_checks
