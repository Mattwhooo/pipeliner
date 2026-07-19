$LOAD_PATH.unshift File.expand_path("test", Dir.pwd)
require_relative "test/test_helper"
ActionCable::Server::Base
Dir.glob("test/**/*_test.rb").each { |f| require File.expand_path(f) }
