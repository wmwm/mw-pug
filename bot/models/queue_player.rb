require_relative '../config/database'

class QueuePlayer < Sequel::Model
  plugin :timestamps, update_on_create: true
  
  many_to_one :player
  
  def self.current_queue
    where(status: ['queued', 'ready']).order(:joined_at)
  end
  
  def self.ready_players
    where(status: 'ready').order(:ready_at)
  end
  
  def self.clear_queue
    where(status: ['queued', 'ready']).delete
  end
  
  def waiting_time
    return 0 unless joined_at
    
    (Time.now - joined_at).to_i
  end
  
  def waiting_time_formatted
    seconds = waiting_time
    if seconds < 60
      "#{seconds}s"
    else
      minutes = seconds / 60
      remaining_seconds = seconds % 60
      "#{minutes}m #{remaining_seconds}s"
    end
  end
end
