require 'rspec'
require 'yaml'
require 'time'
require 'logger'

RSpec.configure do |config|
  config.color = true
  config.formatter = :documentation
  
  # Clean up any test state before each example
  config.before(:each) do
    # Add any test setup here
  end
  
  # Clean up after each example
  config.after(:each) do
    # Add any test cleanup here
  end
end
