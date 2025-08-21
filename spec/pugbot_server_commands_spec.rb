require 'spec_helper'
require_relative '../bot/pugbot_new'

RSpec.describe PugBot do
  let(:bot_instance) { PugBot.new }
  let(:aws_service) { instance_double(AwsService) }
  let(:user) { instance_double(Discordrb::User) }
  let(:channel) { instance_double(Discordrb::Channel) }
  let(:event) { double('event', user: user, channel: channel) }

  before do
    # Inject stubbed AWS service
    bot_instance.instance_variable_set(:@aws_service, aws_service)
    # Stub AWS environment validation
    allow(bot_instance).to receive(:verify_aws_environment).and_return({ valid: true })
    # Stub Discordrb send_embed to return embed
    allow(channel).to receive(:send_embed)
  end

  describe '!startserver' do
    it 'sends success embed on happy path' do
      result = {
        success: true,
        aws_instance_id: 'i-123',
        server_id: 42,
        region: 'Sydney',
        map: 'dm4',
        status: 'running',
        public_ip: '1.2.3.4'
      }
      allow(aws_service).to receive(:deploy_server).and_return(result)
      # Stub event.respond and return a dummy message
      allow(event).to receive(:respond).and_return(double(delete: nil))

      # Call the command handler
      handler = bot_instance.instance_variable_get(:@bot).commands['startserver']
      handler.call(event, 'dm4')

      expect(channel).to have_received(:send_embed) do |_, embed|
        expect(embed.title).to eq("✅ Server Deployed Successfully")
        expect(embed.fields.map(&:name)).to include("🔍 Instance ID", "🌐 Region", "🗺️ Map", "🎮 Connect Command")
      end
    end

    it 'sends error embed on AWS failure' do
      allow(aws_service).to receive(:deploy_server).and_return({ success: false, error: 'AWSError' })
      allow(event).to receive(:respond).and_return(double(delete: nil))

      handler = bot_instance.instance_variable_get(:@bot).commands['startserver']
      handler.call(event, 'dm4')

      expect(channel).to have_received(:send_embed) do |_, embed|
        expect(embed.title).to eq("❌ Server Deployment Failed")
        expect(embed.description).to include("could not be deployed")
        expect(embed.fields.first.name).to eq("Error Details")
      end
    end
  end

  describe '!servers' do
    it 'shows no servers message when empty' do
      allow(event).to receive(:respond).and_return(double(delete: nil))
      allow(aws_service).to receive(:list_active_servers).and_return([])

      handler = bot_instance.instance_variable_get(:@bot).commands['servers']
      handler.call(event)

      expect(channel).to have_received(:send_embed) do |_, embed|
        expect(embed.description).to include("No active servers found")
      end
    end

    it 'lists active servers in embed' do
      server_info = {
        success: true,
        aws_instance_id: 'i-123',
        region: 'Sydney',
        map: 'dm4',
        status: 'running',
        public_ip: '1.2.3.4'
      }
      allow(event).to receive(:respond).and_return(double(delete: nil))
      allow(aws_service).to receive(:list_active_servers).and_return([server_info])

      handler = bot_instance.instance_variable_get(:@bot).commands['servers']
      handler.call(event)

      expect(channel).to have_received(:send_embed) do |_, embed|
        expect(embed.title).to include("Active FortressOne Servers")
        field = embed.fields.first
        expect(field.name).to include("Server (i-123)")
        expect(field.value).to include("connect 1.2.3.4:27500")
      end
    end
  end

  describe '!serverstatus' do
    it 'provides status for specific server' do
      status = { success: true, aws_instance_id: 'i-123', status: 'running', public_ip: '1.2.3.4', region: 'Sydney', map: 'dm4', uptime: '5m', player_count: 3 }
      allow(event).to receive(:respond).and_return(double(delete: nil))
      allow(aws_service).to receive(:get_server_status).with('i-123').and_return(status)

      handler = bot_instance.instance_variable_get(:@bot).commands['serverstatus']
      handler.call(event, 'i-123')

      expect(channel).to have_received(:send_embed) do |_, embed|
        expect(embed.title).to eq("🖥️ Server Status")
        expect(embed.fields.map(&:name)).to include("🔍 Instance ID", "🖥️ Server IP")
      end
    end
  end

  describe '!stopserver' do
    let(:message_double) { double('message', react: nil, await_reaction: reaction) }
    let(:confirmation_reaction) { double('reaction', emoji: double(name: '✅')) }
    let(:reaction) { confirmation_reaction }

    before do
      # When calling event.respond for confirmation, return message_double
      allow(event).to receive(:respond).and_return(message_double, double(delete: nil))
      allow(event).to receive(:message).and_return(message_double)
      allow(aws_service).to receive(:terminate_server).with('i-123').and_return({ success: true })
    end

    it 'terminates server on confirmation' do
      handler = bot_instance.instance_variable_get(:@bot).commands['stopserver']
      handler.call(event, 'i-123')

      expect(event).to have_received(:respond).with(/Processing:/)
      expect(aws_service).to have_received(:terminate_server).with('i-123')
    end

    it 'cancels termination on negative reaction' do
      negative_reaction = double('reaction', emoji: double(name: '❌'))
      allow(message_double).to receive(:await_reaction).and_return(negative_reaction)

      handler = bot_instance.instance_variable_get(:@bot).commands['stopserver']
      handler.call(event, 'i-123')

      expect(event).to have_received(:respond).with("❌ **Cancelled:** Server termination cancelled.")
    end
  end
end
