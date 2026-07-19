module Phases
  # A human ratifies a phase gate (docs/execution-model.md: the Manager builds
  # consensus, the Gate ratifies it). Valid from:
  #   - consensus       — the normal human gate
  #   - awaiting_human  — the max-iterations escalation ("approve anyway")
  #   - paused          — "Done" from the paused menu, only once settled (R20,
  #                       R21) — checked live via Convergence since a paused
  #                       phase's workflow status is never refreshed by a tick.
  class Approve
    APPROVABLE_STATUSES = %w[consensus awaiting_human paused].freeze

    # Optional `context` is the human's answer/guidance for the next phase (e.g.
    # answers to the Define phase's open-questions artifact). When present, we
    # seed the next phase's entry-step runs directly with it as feedback, so the
    # worker picks up the context instead of the Manager dispatching them empty.
    def self.call(phase:, user:, note: nil, context: nil)
      new(phase:, user:, note:, context:).call
    end

    def initialize(phase:, user:, note:, context:)
      @phase = phase
      @user = user
      @note = note
      @context = context
    end

    def call
      unless @phase.status.in?(APPROVABLE_STATUSES)
        return Result.failure(:not_approvable, record: @phase)
      end
      if @phase.paused? && !Convergence.phase_settled?(@phase)
        return Result.failure(:not_settled, record: @phase)
      end

      ApplicationRecord.transaction do
        @phase.approvals.create!(user: @user, decision: "approve", note: @note)
        @phase.update!(status: "approved")
      end
      Dashboard::Broadcast.call(pipeline: @phase.pipeline, activity: true)
      advanced = Advance.call(phase: @phase)

      # Advance returns the next phase (or the pipeline when Review completes);
      # only seed when there is a next phase and the human supplied context.
      if @context.present? && advanced.value.is_a?(Phase)
        seed_next_phase(advanced.value)
      end

      Result.success(@phase)
    end

    private

    # Entry steps = the next phase's worker-executed steps with no worker
    # predecessors (the roots the Manager would otherwise dispatch first).
    def seed_next_phase(next_phase)
      seeded = []
      entry_steps(next_phase).each do |step|
        next if step.active_run?

        run = create_seeded_run(step)
        seeded << run if run
      end
      seeded.each { |run| StepRuns::BroadcastCard.call(run) }
    end

    def entry_steps(next_phase)
      next_phase.workflows.flat_map(&:steps).select do |step|
        step.worker_executed? && step.worker_predecessors.empty?
      end
    end

    def create_seeded_run(step)
      iteration = (step.step_runs.maximum(:iteration) || 0) + 1
      step.step_runs.create!(
        state: "ready",
        iteration: iteration,
        required_role: step.role,
        feedback: [ { "from" => "human-gate", "issue" => @context, "severity" => "major" } ]
      )
    rescue ActiveRecord::RecordNotUnique
      # The Manager raced us and dispatched this entry step first — nothing to do.
      nil
    end
  end
end
