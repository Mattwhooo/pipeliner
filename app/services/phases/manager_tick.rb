module Phases
  # The deterministic core of the phase Manager (docs/execution-model.md —
  # "Manager-driven consensus loop"; decision M5 = hybrid).
  #
  # One tick advances a running phase by exactly the moves the rules force:
  #   1. Dispatch  — fan out ready runs along `depends_on` as predecessors succeed.
  #   2. Route     — a critic's `needs_work` verdict re-runs its `route_to` target
  #                  at the next iteration, carrying the findings as feedback; the
  #                  critic then re-runs once its target succeeds.
  #   3. Converge  — all worker steps succeeded and every critic `pass`/`n_a` →
  #                  workflow converged; all workflows converged → phase consensus,
  #                  then the gate advances the pipeline (auto) or waits (human).
  #   4. Escalate  — exceeding a workflow's `max_iterations` parks the phase and
  #                  pipeline at `awaiting_human`.
  # Every routing/consensus/escalation move records a ManagerDecision.
  #
  # ┌───────────────────────── LLM-judgment seam (OUT OF SCOPE) ────────────────┐
  # │ This service is the *deterministic* half of the hybrid Manager. It decides │
  # │ consensus by unanimous critic pass and routes strictly along `route_to`    │
  # │ edges. The LLM half (decision M5) will plug in at two clearly-marked       │
  # │ points below — `consensus_reached?` (declare consensus despite minor       │
  # │ dissent / weigh severity) and `route_critic_feedback` (choose a target     │
  # │ when the edge is ambiguous or absent). Keep this path as the fallback.     │
  # └────────────────────────────────────────────────────────────────────────────┘
  class ManagerTick
    ACTIVE_STATES = %w[ready claimed running].freeze
    RESOLVED_VERDICTS = %w[pass not_applicable].freeze

    def self.call(phase:)
      new(phase:).call
    end

    def initialize(phase:)
      @phase = phase
      @affected_runs = []
      @affected_phases = []
      @affected_decisions = []
      @pending_rework = nil
    end

    def call
      return Result.failure(:not_running) unless @phase.running?

      ApplicationRecord.transaction do
        catch(:halt) do
          @phase.workflows.each do |workflow|
            dispatch_ready_steps(workflow)
            route_critic_feedback(workflow)
          end
          settle_convergence
        end
      end

      # Inter-phase rework runs as its own top-level action AFTER this tick's
      # transaction commits — it owns its own transaction and broadcasts, and it
      # mutates this phase's status (or escalates on cap), so it must not be
      # entangled with the tick's transaction.
      perform_pending_rework
      broadcast_affected
      Result.success(@phase)
    end

    private

    # --- 1. Dispatch --------------------------------------------------------

    # Create a ready run for every worker-executed step whose predecessors have
    # succeeded and that has no run yet at that iteration. This one rule covers
    # both first dispatch (roots at iteration 1) and a critic re-running after
    # its routed builder succeeds at a higher iteration.
    def dispatch_ready_steps(workflow)
      workflow.steps.each do |step|
        next unless step.worker_executed?
        next if step.active_run?

        predecessors = step.worker_predecessors
        # A predecessor only unblocks a dependent once its branch has MERGED —
        # a merely-succeeded run's artifacts aren't on the pipeline branch yet,
        # so the dependent's worktree wouldn't contain them.
        next unless predecessors.all? { |p| p.latest_run&.succeeded? && p.latest_run.merged? }

        target_iteration = predecessors.filter_map { |p| p.latest_run.iteration }.max || 1
        next unless current_iteration(step) < target_iteration

        create_run(step, iteration: target_iteration)
      end
    end

    # --- 2. Route feedback --------------------------------------------------

    def route_critic_feedback(workflow)
      workflow.steps.select(&:type_critic?).each do |critic|
        run = critic.latest_run
        next unless run&.succeeded? && run.verdict_status == "needs_work"

        # LLM-judgment seam: target selection is edge-driven here. The hybrid
        # Manager would instead choose the responsible step from the findings.
        targets = critic.route_targets
        if targets.any?
          targets.each { |target| route_to_target(workflow, critic, run, target) }
        else
          # No in-phase route: the problem is rooted in an earlier phase. Route
          # the whole loop back (docs/execution-model.md — inter-phase rework).
          queue_inter_phase_rework(critic, run)
        end
      end
    end

    # A critic that returned needs_work with no route_to edge means the fix lives
    # in an earlier phase (a requirement unimplemented, a wrong plan). Route back
    # to the NEAREST earlier phase that has a builder to correct it. Deferred to
    # after the transaction (see perform_pending_rework); throw :halt so the rest
    # of this tick doesn't run against a phase this is about to reset.
    def queue_inter_phase_rework(critic, critic_run)
      target = nearest_earlier_builder_phase
      return if target.nil?
      # Re-trigger guard: the tick runs every ~10s while the critic's verdict
      # stands. Rework exactly once per critic verdict — skip if we already routed
      # a rework from this phase after this critic run finished (a later critic
      # re-run has a newer finished_at, so a genuine new verdict re-triggers).
      return if reworked_since?(critic_run)

      @pending_rework = {
        from_phase: @phase,
        target_phase: target,
        findings: critic_run.findings,
        reason: "Critic #{critic.slug} needs_work with no in-phase route",
        mode: "automated",
        raised_by: "agent"
      }
      throw :halt
    end

    def perform_pending_rework
      return unless @pending_rework

      ReworkToPhase.call(**@pending_rework)
    end

    def nearest_earlier_builder_phase
      @phase.pipeline.phases
        .where("position < ?", @phase.position)
        .reorder(position: :desc)
        .detect { |phase| phase.workflows.any? { |w| w.steps.any?(&:type_builder?) } }
    end

    def reworked_since?(critic_run)
      since = critic_run.finished_at || critic_run.created_at
      @phase.pipeline.rework_events
        .where(from_phase: @phase)
        .where("rework_events.created_at > ?", since)
        .exists?
    end

    def route_to_target(workflow, critic, critic_run, target)
      return unless target.worker_executed?
      return if target.active_run?
      # Already routed for this verdict once the target moved past the critic.
      return unless current_iteration(target) <= critic_run.iteration

      new_iteration = current_iteration(target) + 1
      if new_iteration > workflow.max_iterations
        escalate(workflow, critic, critic_run, new_iteration)
      else
        create_run(target, iteration: new_iteration, feedback: critic_run.findings)
        record_decision(
          decision: "route_to",
          iteration: new_iteration,
          route_to: [ target.slug ],
          rationale: "Critic #{critic.slug} returned needs_work at iteration " \
            "#{critic_run.iteration}; routing #{critic_run.findings.size} finding(s) " \
            "to #{target.slug} for iteration #{new_iteration}."
        )
      end
    end

    def escalate(workflow, critic, critic_run, attempted_iteration)
      @phase.update!(status: "awaiting_human")
      @phase.pipeline.update!(status: "awaiting_human")
      @affected_phases << @phase
      record_decision(
        decision: "escalate",
        iteration: attempted_iteration,
        rationale: "Workflow #{workflow.slug} would exceed max_iterations " \
          "(#{workflow.max_iterations}): critic #{critic.slug} still needs_work at " \
          "iteration #{critic_run.iteration}. Escalating to a human."
      )
      throw :halt
    end

    # --- 3. Converge + gate -------------------------------------------------

    def settle_convergence
      @phase.workflows.each do |workflow|
        workflow.update!(status: "converged") if workflow_converged?(workflow)
      end
      return unless @phase.workflows.all? { |w| w.status == "converged" }

      reach_consensus
    end

    def workflow_converged?(workflow)
      worker_steps = workflow.steps.select(&:worker_executed?)
      return false if worker_steps.empty?
      # Require merged, not just succeeded: a phase can't reach consensus while a
      # step's work is still sitting unmerged on its step branch.
      return false unless worker_steps.all? { |s| s.latest_run&.succeeded? && s.latest_run.merged? }

      # LLM-judgment seam: consensus here is a mechanical unanimous critic pass.
      # The hybrid Manager may declare consensus despite minor dissent (weighing
      # finding severity) or withhold it despite a nominal pass.
      consensus_reached?(worker_steps)
    end

    def consensus_reached?(worker_steps)
      worker_steps.select(&:type_critic?).all? do |critic|
        RESOLVED_VERDICTS.include?(critic.latest_run.verdict_status)
      end
    end

    def reach_consensus
      @phase.update!(status: "consensus")
      record_decision(
        decision: "consensus",
        iteration: phase_iteration,
        rationale: "All workflows converged: every worker step succeeded and " \
          "every critic returned pass/not_applicable."
      )
      apply_gate
    end

    def apply_gate
      if @phase.gate_auto?
        @phase.update!(status: "approved")
        advance_pipeline
      else
        # Human gate: park for approval (surfaced by the board's gate banner).
        @phase.pipeline.update!(status: "awaiting_human")
        @affected_phases << @phase
      end
    end

    def advance_pipeline
      Advance.call(phase: @phase)
    end

    # --- helpers ------------------------------------------------------------

    def create_run(step, iteration:, feedback: [])
      run = step.step_runs.create!(
        state: "ready",
        iteration: iteration,
        required_role: step.role,
        feedback: feedback
      )
      @affected_runs << run
      run
    end

    def current_iteration(step)
      step.step_runs.maximum(:iteration) || 0
    end

    def phase_iteration
      StepRun.where(step: Step.where(workflow: @phase.workflows)).maximum(:iteration) || 1
    end

    def record_decision(decision:, iteration:, rationale:, route_to: [])
      created = @phase.manager_decisions.create!(
        decision: decision,
        iteration: iteration,
        route_to: route_to,
        rationale: rationale
      )
      @affected_decisions << created if decision.in?(%w[consensus escalate])
      created
    end

    def broadcast_affected
      @affected_runs.each { |run| StepRuns::BroadcastCard.call(run) }
      @affected_phases.each { |phase| BroadcastColumn.call(phase) }
      Dashboard::Broadcast.call(pipeline: @phase.pipeline, activity: true) if @affected_decisions.any?
    end
  end
end
