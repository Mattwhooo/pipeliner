$LOAD_PATH.unshift File.expand_path("test", __dir__)
require "test_helper"
ActionCable::Server::Base
Dir.glob(File.expand_path("test/**/*_test.rb", __dir__)).each { |f| require f }
