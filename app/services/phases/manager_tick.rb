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
  # │ points — `Phases::Convergence.workflow_converged?` (declare consensus      │
  # │ despite minor dissent / weigh severity) and `route_critic_feedback` below  │
  # │ (choose a target when the edge is ambiguous or absent). Keep this path as  │
  # │ the fallback.                                                              │
  # └────────────────────────────────────────────────────────────────────────────┘
  class ManagerTick
    ACTIVE_STATES = %w[ready claimed running].freeze

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

      # A restart step failed/got stuck — don't leave the phase stalled at
      # "running" forever; hand it back to the paused menu with the failure
      # visible (R25, R26).
      if @phase.restart_in_progress? && restart_step_failed?
        abort_restart
        broadcast_affected
        return Result.success(@phase)
      end

      # Pause was requested while a step was in flight — wait for it to
      # finish, dispatch nothing new in the meantime (R2, R3, R27).
      if @phase.pause_requested? && !@phase.restart_in_progress?
        settle_pause
        broadcast_affected
        return Result.success(@phase)
      end

      ApplicationRecord.transaction do
        catch(:halt) do
          @phase.workflows.each do |workflow|
            dispatch_ready_steps(workflow)
            escalate_failed_steps(workflow)
            route_critic_feedback(workflow)
            route_human_feedback(workflow)
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
      # Gate-wait, escalation, consensus and advance change only phase/pipeline
      # status — no card — so the pipeline summary must be refreshed here or those
      # transitions would be invisible until reload (R7, R14).
      Pipelines::BroadcastStatus.call(@phase.pipeline)
      Result.success(@phase)
    end

    private

    # --- Pause / restart -----------------------------------------------------

    def restart_step_failed?
      @phase.workflows.flat_map(&:steps)
        .any? { |s| s.latest_run&.state&.in?(%w[failed stuck]) }
    end

    def abort_restart
      @phase.update!(status: "paused", restart_in_progress: false, restart_feedback: [])
      @affected_phases << @phase
    end

    def settle_pause
      return if @phase.any_step_active?

      @phase.update!(status: "paused", pause_requested: false, pause_requested_at: nil)
      @affected_phases << @phase
    end

    # --- 1. Dispatch --------------------------------------------------------

    # Create a ready run for every worker-executed step whose predecessors have
    # succeeded and that has no run yet at that iteration. This one rule covers
    # both first dispatch (roots at iteration 1) and a critic re-running after
    # its routed builder succeeds at a higher iteration.
    #
    # Skip-unchanged: a re-dispatch whose inputs + feedback are byte-identical to
    # what the step's last succeeded run consumed is fast-forwarded to the new
    # iteration instead of re-running the worker (see dispatch_or_reuse). This is
    # what stops an untouched step downstream of a *reused* predecessor from
    # re-running as the iteration climbs — only steps downstream of an actually
    # changed artifact do real work.
    def dispatch_ready_steps(workflow)
      workflow.steps.each do |step|
        next unless step.worker_executed?
        next if step.active_run?

        predecessors = step.worker_predecessors
        next unless predecessors.all? { |p| predecessor_satisfied?(p) }

        target_iteration = predecessors.filter_map { |p| p.latest_run.iteration }.max || 1
        next unless current_iteration(step) < target_iteration

        dispatch_or_reuse(step, iteration: target_iteration, feedback: restart_carry_feedback)
      end
    end

    # Dispatch a fresh worker run, unless the step's declared inputs + this
    # feedback fingerprint-match a prior succeeded+merged run — in which case that
    # run's output still stands, so reuse it at the new iteration (a "skip"
    # decision) rather than re-running the worker. Reuse is disabled during a
    # restart: "Repeat from the Beginning" deliberately redoes the work even when
    # nothing changed (R15/R19).
    def dispatch_or_reuse(step, iteration:, feedback:)
      fingerprint = InputFingerprint.for(step, feedback: feedback)
      reuse = @phase.restart_in_progress? ? nil : reusable_run(step, fingerprint)
      if reuse
        reuse_run(step, reuse, iteration: iteration, fingerprint: fingerprint)
      else
        create_run(step, iteration: iteration, feedback: feedback, fingerprint: fingerprint)
      end
    end

    # The step's last succeeded+merged run whose recorded input fingerprint equals
    # `fingerprint`. A blank fingerprint (runs predating fingerprinting, or a
    # first dispatch with nothing to match) never reuses, so those always run for
    # real. Sharded runs are excluded — fan-out reuse would need per-shard
    # bookkeeping this doesn't model.
    def reusable_run(step, fingerprint)
      return nil if fingerprint.blank?

      step.step_runs
        .where(state: "succeeded", input_fingerprint: fingerprint, shard_key: nil)
        .where.not(merged_at: nil)
        .order(:iteration, :attempt).last
    end

    # Fast-forward `source`'s already-merged output to a new iteration: a
    # succeeded+merged run carrying the same commit/result/verdict, no worker and
    # no new merge needed (the artifacts are already on the branch at their stable
    # paths). A critic's verdict rides along, which is sound precisely because its
    # inputs are unchanged. Recorded as a "skip" decision for the audit trail.
    def reuse_run(step, source, iteration:, fingerprint:)
      run = step.step_runs.create!(
        state: "succeeded",
        iteration: iteration,
        required_role: step.role,
        feedback: source.feedback,
        input_fingerprint: fingerprint,
        result: source.result,
        verdict: source.verdict,
        commit_sha: source.commit_sha,
        started_at: Time.current,
        finished_at: Time.current,
        merged_at: Time.current
      )
      @affected_runs << run
      record_decision(
        decision: "skip",
        iteration: iteration,
        route_to: [ step.slug ],
        rationale: "#{step.slug}'s inputs are unchanged since its succeeded run at " \
          "iteration #{source.iteration}; reusing that output at iteration " \
          "#{iteration} instead of re-dispatching the worker."
      )
      run
    end

    # Carry a restart's human-tagged feedback (RestartDefine#carried_feedback)
    # onto every step the cascade dispatches, not just the first (which
    # RestartDefine already seeded directly) — R18.
    def restart_carry_feedback
      @phase.restart_in_progress? ? @phase.restart_feedback : []
    end

    # A predecessor unblocks its dependents only once its latest run has
    # succeeded AND merged — a merely-succeeded run's artifacts aren't on the
    # pipeline branch yet, so the dependent's worktree wouldn't contain them.
    # A CRITIC predecessor additionally gates on its verdict: dependents wait
    # until the critic actually PASSES (pass/not_applicable), so a decision-tree
    # edge past a critic advances only when its check is satisfied — this is what
    # lets Define's Clarifying-Questions critic hold the loop until the task is
    # fully defined ("its pass lets the DAG continue"). A needs_work critic
    # routes elsewhere and never unblocks what depends on it.
    def predecessor_satisfied?(step)
      run = step.latest_run
      return false unless run&.succeeded? && run.merged?
      return true unless step.type_critic?

      Convergence::RESOLVED_VERDICTS.include?(run.verdict_status)
    end

    # --- 2. Route feedback --------------------------------------------------

    def escalate_failed_steps(workflow)
      workflow.steps.select(&:worker_executed?).each do |step|
        run = step.latest_run
        next unless run&.failed?

        escalate_blocked(step, "latest run failed (attempt #{run.attempt}): " \
          "#{run.result&.dig("summary").to_s[0, 120]}")
      end
    end

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
      return escalate_blocked(critic,
        "needs_work with no in-phase route and no earlier builder phase") if target.nil?
      # Re-trigger guard: the tick runs every ~10s while the critic's verdict
      # stands. Rework exactly once per critic verdict — skip if we already routed
      # a rework from this phase after this critic run finished (a later critic
      # re-run has a newer finished_at, so a genuine new verdict re-triggers).
      # A verdict that stands AFTER that rework came back means the automated
      # loop has no further move — that is a judgment call, so escalate to the
      # human gate instead of silently spinning.
      return escalate_blocked(critic,
        "needs_work persists after automated rework (or rework already spent)") if reworked_since?(critic_run)

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

    # A phase with no automated move left (unroutable needs_work, exhausted
    # rework, hard-failed step) parks at the human gate instead of spinning.
    def escalate_blocked(step, why)
      @phase.update!(status: "awaiting_human")
      @phase.pipeline.update!(status: "awaiting_human")
      @affected_phases << @phase
      record_decision(
        decision: "escalate",
        iteration: phase_iteration,
        rationale: "#{step.slug}: #{why}. Awaiting human judgment " \
          "(approve, send back, or re-run the step)."
      )
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
      return dispatch_human_feedback(critic, critic_run, target) if target.type_human?
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

    # A critic whose route_to target is a HUMAN step (Define's Clarifying
    # Questions → Human Feedback): a needs_work verdict hands the findings (the
    # open questions) to the human to answer in the UI, exactly once per verdict.
    # The run is created at the critic's own iteration so it sits level with the
    # verdict that raised it; once the human submits, route_human_feedback re-runs
    # the critic at iteration+1 (moving it past this ask, which closes the guard).
    def dispatch_human_feedback(critic, critic_run, human_step)
      return if human_step.active_run?
      # One ask per verdict: a human run already at/after this critic's iteration
      # was raised for this verdict (or a later one) — don't stack another.
      return if current_iteration(human_step) >= critic_run.iteration

      create_run(human_step, iteration: critic_run.iteration, feedback: critic_run.findings)
      record_decision(
        decision: "route_to",
        iteration: critic_run.iteration,
        route_to: [ human_step.slug ],
        rationale: "Critic #{critic.slug} returned needs_work at iteration " \
          "#{critic_run.iteration}; awaiting the human's answers to " \
          "#{critic_run.findings.size} open question(s) before continuing."
      )
    end

    # The mirror of route_critic_feedback for human steps: once a human submits
    # their feedback run (Phases::SubmitHumanFeedback marks it succeeded), send
    # control along the human step's route_to edge — re-running the critic (Define's
    # Clarifying Questions) at the next iteration with every answer given so far as
    # feedback, so it can decide whether the task is now fully defined.
    def route_human_feedback(workflow)
      workflow.steps.select(&:type_human?).each do |human_step|
        run = human_step.latest_run
        next unless run&.succeeded?

        human_step.route_targets.each do |target|
          next unless target.worker_executed?
          next if target.active_run?
          # Re-run once per answer: skip once the target has already advanced to
          # (or past) this human run's iteration.
          next unless current_iteration(target) <= run.iteration

          new_iteration = current_iteration(target) + 1
          create_run(target, iteration: new_iteration, feedback: human_feedback_so_far(workflow))
          record_decision(
            decision: "route_to",
            iteration: new_iteration,
            route_to: [ target.slug ],
            rationale: "Human answered #{human_step.slug}; re-running #{target.slug} " \
              "at iteration #{new_iteration} with the answers to reassess whether the " \
              "task is fully defined."
          )
        end
      end
    end

    # Every answer the human has submitted to this workflow's human steps so far,
    # as feedback entries — a re-run of Clarifying Questions is given the full
    # history, not just the latest answer (the worker reads it from input.json;
    # the answers live in the DB, not on the branch, so feedback is the delivery
    # channel — same convention as Phases::AnswerQuestions).
    def human_feedback_so_far(workflow)
      workflow.steps.select(&:type_human?).flat_map(&:step_runs)
        .select { |r| r.succeeded? && r.result.is_a?(Hash) }
        .sort_by { |r| [ r.iteration, r.id ] }
        .filter_map do |r|
          answers = r.result.dig("artifacts", "human_answers").presence
          answers && { "from" => "human", "issue" => answers, "severity" => "info" }
        end
    end

    def escalate(workflow, critic, critic_run, attempted_iteration)
      @phase.update!(status: "awaiting_human", restart_in_progress: false)
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
        workflow.update!(status: "converged") if Convergence.workflow_converged?(workflow)
      end
      return unless @phase.workflows.all? { |w| w.status == "converged" }

      @phase.restart_in_progress? ? settle_restart : reach_consensus
    end

    # "Repeat from the Beginning" converged — land back on the paused menu
    # (with fresh results already on the pipeline branch) instead of the
    # normal gate (R19).
    def settle_restart
      @phase.update!(status: "paused", restart_in_progress: false, restart_feedback: [])
      record_decision(
        decision: "restart_complete",
        iteration: phase_iteration,
        rationale: "Repeat-from-the-Beginning converged; returned to the paused menu with fresh results."
      )
      @affected_phases << @phase
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

    def create_run(step, iteration:, feedback: [], fingerprint: nil)
      # A human step is dispatched into a run the product owns — no worker claims
      # it — so it starts in awaiting_input, not ready (see StepRun state enum).
      # Every worker run records the fingerprint of what it consumes so a later
      # re-dispatch with the same inputs can reuse it (see dispatch_or_reuse).
      run = step.step_runs.create!(
        state: step.type_human? ? "awaiting_input" : "ready",
        iteration: iteration,
        required_role: step.role,
        feedback: feedback,
        input_fingerprint: fingerprint || InputFingerprint.for(step, feedback: feedback)
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
