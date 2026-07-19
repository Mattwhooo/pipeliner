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
      return Result.failure(:not_pausable, record: @phase) unless pausable?
      return Result.success(@phase) if @phase.pause_requested? # idempotent re-click

      if @phase.any_step_active?
        @phase.update!(pause_requested: true, pause_requested_at: Time.current)
      else
        @phase.update!(status: "paused", pause_requested: false, pause_requested_at: nil)
      end

      BroadcastColumn.call(@phase)
      Result.success(@phase)
    end

    private

    # Pausing (and the rest of the paused menu) is a Define-only feature —
    # match Phases::AnswerQuestions#answerable?. Without this, a crafted POST
    # to /phases/:id/pause on any running non-Define phase would set it to
    # "paused", which Phases::TickAll skips and the board has no UI to resume
    # from, stranding the phase.
    def pausable?
      @phase.define_phase? && @phase.status.in?(PAUSABLE_STATUSES)
    end
  end
end
