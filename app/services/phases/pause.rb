module Phases
  # A human asks Define to hold (R1-R4). If a step is already in flight, we
  # can't freeze it (60s leases — docs/execution-model.md constraints), so we
  # only flag the request; ManagerTick settles it into `paused` once idle
  # (R3). If nothing is in flight, pause takes effect immediately.
  class Pause
    PAUSABLE_STATUSES = %w[running].freeze

    def self.call(phase:, user:)
      new(phase:, user:).call
    end

    def initialize(phase:, user:)
      @phase = phase
      @user = user
    end

    def call
      return Result.failure(:not_pausable, record: @phase) unless @phase.status.in?(PAUSABLE_STATUSES)
      return Result.success(@phase) if @phase.pause_requested? # idempotent re-click

      if @phase.any_step_active?
        @phase.update!(pause_requested: true, pause_requested_at: Time.current)
      else
        @phase.update!(status: "paused", pause_requested: false, pause_requested_at: nil)
      end

      BroadcastColumn.call(@phase)
      Result.success(@phase)
    end
  end
end
