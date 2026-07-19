module Phases
  # A human ratifies a phase gate (docs/execution-model.md: the Manager builds
  # consensus, the Gate ratifies it). Valid from:
  #   - consensus       — the normal human gate
  #   - awaiting_human  — the max-iterations escalation ("approve anyway")
  class Approve
    APPROVABLE_STATUSES = %w[consensus awaiting_human].freeze

    def self.call(phase:, user:, note: nil)
      new(phase:, user:, note:).call
    end

    def initialize(phase:, user:, note:)
      @phase = phase
      @user = user
      @note = note
    end

    def call
      unless @phase.status.in?(APPROVABLE_STATUSES)
        return Result.failure(:not_approvable, record: @phase)
      end

      ApplicationRecord.transaction do
        @phase.approvals.create!(user: @user, decision: "approve", note: @note)
        @phase.update!(status: "approved")
      end
      Advance.call(phase: @phase)

      Result.success(@phase)
    end
  end
end
