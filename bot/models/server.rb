require_relative '../config/database'

class Server < Sequel::Model
  plugin :timestamps, update_on_create: true
  
  one_to_many :matches
  
  def self.active
    where(status: ['launching', 'running'])
  end
  
  def self.find_by_instance_id(instance_id)
    find(aws_instance_id: instance_id)
  end
  
  def uptime
    return 0 unless launched_at
    
    (Time.now - launched_at).to_i
  end
  
  def uptime_formatted
    seconds = uptime
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    seconds = seconds % 60
    
    if hours > 0
      "#{hours}h #{minutes}m"
    elsif minutes > 0
      "#{minutes}m #{seconds}s"
    else
      "#{seconds}s"
    end
  end
  
  def connection_string
    return nil unless public_ip
    
    "#{public_ip}:#{port || 27500}"
  end
  
  def status_url
    return nil unless public_ip
    
    "http://#{public_ip}:28000/status"
  end
  
  def update_player_count(count)
    update(player_count: count, last_ping: Time.now)
  end
  
  def mark_offline
    update(status: 'stopped', player_count: 0)
  end
end
