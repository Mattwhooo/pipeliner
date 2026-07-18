module StepRuns
  class SweepJob < ApplicationJob
    queue_as :default

    def perform = StepRuns::Sweep.call
  end
end
