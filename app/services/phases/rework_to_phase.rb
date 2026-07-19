module Phases
  # Inter-phase rework routing (docs/execution-model.md — "Inter-phase rework
  # routing"; decision C3 = forward-only). A later phase sends work back to an
  # EARLIER phase with structured feedback: the target phase re-opens with its
  # prior artifacts PLUS the feedback and flows forward again.
  #
  # Forward-only unwind: we never rewrite history or roll the branch back. The
  # target phase and everything after it drop back to pending/running; their
  # steps re-run at LATER iterations as the flow returns (the Manager's dispatch
  # re-creates them once a predecessor has merged at a higher iteration). No git
  # rollback happens here.
  #
  # Two modes, both recorded the same way: "automated" (the decider already had
  # what it needed and something was simply missed — route straight back) and
  # "human" (a person is supplying missing context; the pause/gate itself is the
  # caller's concern). A per-target cap prevents infinite Define<->Review cycles:
  # on cap the from_phase + pipeline park at awaiting_human for human guidance.
  class ReworkToPhase
    MAX_REWORKS = 3

    def self.call(from_phase:, target_phase:, findings:, reason:, mode:, raised_by:)
      new(from_phase:, target_phase:, findings:, reason:, mode:, raised_by:).call
    end

    def initialize(from_phase:, target_phase:, findings:, reason:, mode:, raised_by:)
      @from_phase = from_phase
      @target_phase = target_phase
      @findings = Array(findings)
      @reason = reason
      @mode = mode
      @raised_by = raised_by
      @pipeline = from_phase.pipeline
      @changed_phases = []
    end

    def call
      return Result.failure(:invalid_target, record: @target_phase) unless target_earlier?
      return Result.failure(:pipeline_closed, record: @pipeline) if pipeline_closed?
      return cap_exceeded if @target_phase.rework_count >= MAX_REWORKS

      target_step = first_worker_step(@target_phase)
      return Result.failure(:no_target_step, record: @target_phase) if target_step.nil?

      run = nil
      ApplicationRecord.transaction do
        record_rework_event
        reopen_target
        reset_forward_phases
        @pipeline.update!(current_phase: @target_phase.kind, status: "running")
        run = create_feedback_run(target_step)
        record_route_decision(target_step, run)
      end

      # Broadcasts only AFTER the transaction commits — enqueueing a render job
      # mid-transaction would race a rollback (guides/backend-guide.md).
      StepRuns::BroadcastCard.call(run)
      @changed_phases.each { |phase| BroadcastColumn.call(phase) }
      Result.success(run)
    end

    private

    def target_earlier?
      @target_phase.position < @from_phase.position
    end

    def pipeline_closed?
      @pipeline.completed? || @pipeline.aborted?
    end

    # Cap reached: don't loop again — park the deciding phase and the pipeline for
    # a human and record why (mirrors the max-iterations escalation).
    def cap_exceeded
      @from_phase.update!(status: "awaiting_human")
      @pipeline.update!(status: "awaiting_human")
      @from_phase.manager_decisions.create!(
        decision: "escalate",
        iteration: from_phase_iteration,
        rationale: "Rework cap reached: #{@target_phase.kind} has already been " \
          "reworked #{@target_phase.rework_count} time(s) (max #{MAX_REWORKS}). " \
          "Escalating #{@from_phase.kind} to a human instead of routing back again."
      )
      BroadcastColumn.call(@from_phase)
      Result.failure(:rework_cap, record: @from_phase)
    end

    def record_rework_event
      @pipeline.rework_events.create!(
        from_phase: @from_phase,
        target_phase: @target_phase,
        reason: @reason,
        mode: @mode,
        raised_by: @raised_by,
        feedback: @findings
      )
    end

    def reopen_target
      @target_phase.update!(rework_count: @target_phase.rework_count + 1, status: "running")
      @target_phase.workflows.each { |workflow| workflow.update!(status: "running") }
      @changed_phases << @target_phase
    end

    # Everything strictly between the target and the from_phase, plus the
    # from_phase itself, drops to pending. Their steps re-run at later iterations
    # when the flow returns — forward-only, no git rollback.
    def reset_forward_phases
      @pipeline.phases
        .where("position > ? AND position <= ?", @target_phase.position, @from_phase.position)
        .each do |phase|
          phase.update!(status: "pending")
          phase.workflows.each { |workflow| workflow.update!(status: "pending") }
          @changed_phases << phase
        end
    end

    def create_feedback_run(step)
      marker = "rework:#{@from_phase.kind}"
      step.step_runs.create!(
        state: "ready",
        iteration: (step.step_runs.maximum(:iteration) || 0) + 1,
        required_role: step.role,
        feedback: @findings.map { |finding| finding.merge("from" => marker) }
      )
    end

    def record_route_decision(step, run)
      @from_phase.manager_decisions.create!(
        decision: "route_to",
        iteration: run.iteration,
        route_to: [ step.slug ],
        rationale: "#{@raised_by.to_s.capitalize} raised rework from " \
          "#{@from_phase.kind}: #{@reason}. Routing #{@findings.size} finding(s) " \
          "back to #{@target_phase.kind} step #{step.slug} (iteration #{run.iteration})."
      )
    end

    # First worker-executed step of the target phase, by workflow (creation) then
    # step position — the entry point the corrective feedback re-runs from.
    def first_worker_step(phase)
      phase.workflows.order(:id).flat_map { |workflow| workflow.steps.select(&:worker_executed?) }.first
    end

    def from_phase_iteration
      StepRun.where(step: Step.where(workflow: @from_phase.workflows)).maximum(:iteration) || 1
    end
  end
end
