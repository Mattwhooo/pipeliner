module Phases
  # Thin recurring wrapper: ticks the Manager loop for every running phase.
  # Idempotent — safe to run on a short interval (config/recurring.yml).
  class ManagerTickJob < ApplicationJob
    queue_as :default

    def perform = Phases::TickAll.call
  end
end
