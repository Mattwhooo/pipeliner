module Phases
  # Advances every running phase one Manager tick. Called on a recurring
  # schedule (config/recurring.yml) so the consensus loop makes progress
  # without a worker having to poke it. Each phase ticks independently — one
  # phase's failure never blocks the others.
  class TickAll
    def self.call
      new.call
    end

    def call
      ticked = Phase.where(status: "running").find_each.count do |phase|
        ManagerTick.call(phase: phase)
        true
      end
      Result.success(ticked: ticked)
    end
  end
end
