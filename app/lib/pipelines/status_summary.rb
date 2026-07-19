module Pipelines
  # Turns a pipeline's live state into one plain-language sentence answering the
  # operator's core question — "what is happening right now?" (e.g. "Define:
  # requirements is drafting requirements, iteration 3" or "Waiting on human
  # approval at the Plan gate").
  #
  # This is pure *derivation* logic: a side-effect-free domain value object
  # (backend-guide "Domain POROs (values, states)"), callable from the view, the
  # broadcast service, the console, and tests. It performs no writes, so it uses
  # `.for` rather than the verb-first service `.call`.
  #
  # `build` is a total function: the resolution order below ends in an
  # unconditional catch-all, so every pipeline — including future statuses and
  # momentary lulls — resolves to exactly one non-blank Summary (R12).
  #
  # Tone is never a per-branch literal: every branch resolves its tone by looking
  # the governing status up in the same StatusHelper::STATUS_TONES table that
  # status_badge reads, so the summary dot and the pipeline's status badge can
  # never disagree about a state's color (ui-style-guide "status colors are
  # semantic and reserved").
  class StatusSummary
    # Immutable value the view renders. `text` is a complete plain-language
    # sentence (never blank); `tone` is a StatusHelper tone symbol; `phase_label`
    # is the humanized current phase ("Define") or nil.
    Summary = Data.define(:text, :tone, :phase_label) do
      def to_s = text
    end

    # Fallback verbs when a run reports no progress message, keyed by step type.
    TYPE_VERBS = {
      "planner" => "planning",
      "builder" => "building",
      "critic" => "reviewing",
      "manager" => "coordinating",
      "gate" => "awaiting review"
    }.freeze

    def self.for(pipeline) = new(pipeline).build

    def initialize(pipeline)
      @pipeline = pipeline
    end

    # Resolution order — first match wins, most operationally salient first. The
    # final branch has no guard, so this is total (R12).
    def build
      completed_summary ||
        failed_summary ||
        canceled_summary ||
        awaiting_human_summary ||
        blocked_summary ||
        running_summary ||
        not_started_summary ||
        default_summary
    end

    private

    # 1. Completed — all work finished successfully (R8).
    def completed_summary
      return unless @pipeline.completed?

      summary("Completed", "completed")
    end

    # 2. Failed — an error stopped it and it can't continue on its own; always
    #    names the phase (and step when known) with failure wording (R9). Kept
    #    distinct from a deliberate cancel (branch 3): an error stop stays red.
    def failed_summary
      phase, run = failed_context
      return unless phase || run

      phase ||= run.step.workflow.phase
      label = phase.kind.humanize
      text =
        if run
          "Failed in #{label}: #{run.step.role} could not complete"
        else
          "Failed in #{label}"
        end
      summary(text, "failed", label)
    end

    # 3. Canceled / paused — a person stopped it, not an error (R11). Written
    #    state-driven so "Paused" activates automatically if a `paused` status is
    #    ever added; only `aborted` → "Canceled" is reachable today.
    def canceled_summary
      if @pipeline.aborted?
        summary("Canceled", "aborted")
      elsif @pipeline.status == "paused"
        summary("Paused", "paused")
      end
    end

    # 4. Awaiting human — a gate awaiting approval, or an escalation parked for
    #    guidance; names where (R7).
    def awaiting_human_summary
      return unless @pipeline.awaiting_human?

      if (phase = gate_phase)
        label = phase.kind.humanize
        summary("Waiting on human approval at the #{label} gate", "awaiting_human", label)
      elsif (phase = escalated_phase)
        label = phase.kind.humanize
        summary("Paused at #{label}: needs human guidance", "awaiting_human", label)
      else
        label = current_phase_label
        summary("Waiting on human approval at the #{label} gate", "awaiting_human", label)
      end
    end

    # 5. Blocked / stuck — a recoverable wait for capacity, not an error stop
    #    (distinct from R9); still given a truthful sentence (R12).
    def blocked_summary
      return unless @pipeline.blocked? || @pipeline.stuck?

      label = current_phase_label
      summary("Blocked in #{label}: waiting for an available worker", @pipeline.status, label)
    end

    # 6. Running — actively working steps. 1 → full sentence; 2 → name both;
    #    3+ → phase + count only (R3, R5, R6).
    def running_summary
      return unless @pipeline.running?

      phase = current_phase_record
      return unless phase

      active = active_runs(phase)
      return if active.empty? # momentary lull → fall through to the default.

      label = phase.kind.humanize
      text =
        case active.size
        when 1
          "#{label}: #{clause(active.first)}"
        when 2
          "#{label}: #{clause(active[0])} and #{clause(active[1])}"
        else
          "#{label}: #{active.size} steps are running"
        end
      summary(text, "running", label)
    end

    # 7. Not started — exists but no work has begun (R10).
    def not_started_summary
      return unless @pipeline.draft?

      summary("Not started", "draft")
    end

    # 8. Default catch-all (R12, unconditional) — a truthful generic sentence for
    #    any state not matched above, incl. a running-but-idle moment and any
    #    future status. Never blank.
    def default_summary
      phase = current_phase_record
      if @pipeline.running? && phase
        label = phase.kind.humanize
        summary("Working in #{label}", "running", label)
      else
        summary(@pipeline.status.to_s.humanize, @pipeline.status)
      end
    end

    # --- construction -------------------------------------------------------

    def summary(text, status, phase_label = nil)
      Summary.new(text: text, tone: tone_for(status), phase_label: phase_label)
    end

    # Tone always comes from the shared table status_badge reads (F1).
    def tone_for(status)
      StatusHelper::STATUS_TONES.fetch(status.to_s, :muted)
    end

    # One "<role> is <doing>[, iteration <n>]" clause. The iteration suffix is
    # shown only on the 2nd+ pass (R4).
    def clause(run)
      base = "#{run.step.role} is #{doing_for(run)}"
      run.iteration > 1 ? "#{base}, iteration #{run.iteration}" : base
    end

    def doing_for(run)
      message = run.progress.is_a?(Hash) ? run.progress["message"] : nil
      if message.present?
        message[0].downcase + message[1..].to_s
      else
        TYPE_VERBS.fetch(run.step.step_type, "working")
      end
    end

    # --- state reads (Ruby-level so a preloaded tree adds zero queries) ------

    def active_runs(phase)
      runs = steps_in(phase).flat_map { |s| s.step_runs.to_a }.select { |r| leased?(r) }
      runs.sort_by { |r| [ r.state == "running" ? 0 : 1, -r.updated_at.to_f ] }
    end

    def leased?(run)
      run.worker_id.present? && run.state.in?(%w[claimed running])
    end

    # [phase, failed_run] when an error has stopped the pipeline, else nil.
    def failed_context
      failed_phase = phases.find(&:failed?)
      if failed_phase
        [ failed_phase, all_runs_in(failed_phase).find { |r| r.state == "failed" } ]
      else
        run = all_runs.find { |r| r.state == "failed" }
        run ? [ nil, run ] : nil
      end
    end

    def gate_phase
      phases.find do |p|
        p.gate_human? && p.status.in?(%w[consensus approved]) && p.approvals.to_a.empty?
      end
    end

    def escalated_phase
      phases.find { |p| p.status == "awaiting_human" }
    end

    def phases
      @phases ||= @pipeline.phases.to_a
    end

    def current_phase_record
      phases.find { |p| p.kind == @pipeline.current_phase }
    end

    def current_phase_label
      current_phase_record&.kind&.humanize || @pipeline.current_phase.to_s.humanize
    end

    def steps_in(phase)
      phase.workflows.flat_map { |w| w.steps.to_a }
    end

    def all_runs_in(phase)
      steps_in(phase).flat_map { |s| s.step_runs.to_a }
    end

    def all_runs
      phases.flat_map { |p| all_runs_in(p) }
    end
  end
end
