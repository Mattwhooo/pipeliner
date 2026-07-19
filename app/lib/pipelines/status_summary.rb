module Pipelines
  # Turns a pipeline's whole-tree state into a single plain-language sentence —
  # "what is happening right now?" — for the live status summary on the board.
  #
  # This is pure *derivation / state-logic* (backend-guide "Business logic lives
  # in reusable POROs" → "Domain POROs (values, states)"): it performs no writes
  # and makes no HTTP/job assumptions, so it is callable from the view, the
  # broadcast service, the console, and tests. It is not a verb-first service and
  # not a Query (it returns a value, not a Relation), so `app/lib` is its home.
  # It reads only associations, so on a preloaded tree (Pipeline.with_board) the
  # derivation adds zero queries.
  #
  #   summary = Pipelines::StatusSummary.for(pipeline)
  #   summary.text        # => a complete, single-line sentence, never blank (R12)
  #   summary.tone        # => a StatusHelper tone the dot/badge can color (R17)
  #   summary.phase_label # => humanized current/relevant phase ("Define") or nil
  #
  # `build` is a *total* function: its final branch is an unconditional default,
  # so every current or future pipeline status resolves to a truthful, non-blank
  # sentence (R12).
  class StatusSummary
    # A leased run — a worker is actually on it — counts as actively working.
    ACTIVE_STATES = %w[running claimed].freeze

    # Fallback verb per step type when a run reports no progress message (R3/R13).
    TYPE_VERBS = {
      "planner" => "planning",
      "builder" => "building",
      "critic" => "reviewing",
      "manager" => "coordinating",
      "gate" => "awaiting review"
    }.freeze

    # Immutable value the view renders. `.for` (not `.call`) because this is a
    # pure query-by, never a mutation (backend-guide service naming).
    Summary = Data.define(:text, :tone, :phase_label) do
      def to_s = text
    end

    def self.for(pipeline) = new(pipeline).build

    def initialize(pipeline)
      @pipeline = pipeline
    end

    # First match wins, ordered most operationally salient first. The final
    # branch has no guard, so `build` always returns a non-blank Summary (R12).
    def build
      merged || completed || failed || canceled || awaiting_human ||
        blocked || working || not_started || default
    end

    private

    # --- terminal: the PR was merged (past completed) ----------------------
    def merged
      return unless @pipeline.merged?

      summary("Merged", "merged")
    end

    # --- R8: all work finished successfully --------------------------------
    def completed
      return unless @pipeline.completed?

      summary("Completed", "completed")
    end

    # --- R9: an error stopped it; name where it stopped --------------------
    def failed
      phase, step = failed_context
      return unless phase

      text =
        if step
          "Failed in #{humanize(phase.kind)}: #{step.role} could not complete"
        else
          "Failed in #{humanize(phase.kind)}"
        end
      summary(text, "failed", humanize(phase.kind))
    end

    # --- R11: a person deliberately stopped it -----------------------------
    def canceled
      # `aborted` is the cooperative-cancel signal (StepRuns::Heartbeat). A real
      # `paused` status would map to "Paused" here if/when it is added to the
      # enum; until then only "Canceled" is reachable and the default (R12)
      # covers any interim value.
      return unless @pipeline.aborted?

      summary("Canceled", "aborted")
    end

    # --- R7: waiting on a person, and where --------------------------------
    def awaiting_human
      return unless @pipeline.awaiting_human?

      phase = current_phase
      label = phase && humanize(phase.kind)
      text =
        if phase&.gate_human? && phase.consensus?
          "Waiting on human approval at the #{label} gate"
        elsif phase&.awaiting_human?
          "Paused at #{label}: needs human guidance"
        elsif label
          "Waiting on human input at #{label}"
        else
          "Waiting on human input"
        end
      summary(text, "awaiting_human", label)
    end

    # --- recoverable capacity wait (R12): blocked / stuck, no error --------
    def blocked
      return unless @pipeline.blocked? || @pipeline.stuck?

      phase = current_phase
      label = phase && humanize(phase.kind)
      text = label ? "Blocked in #{label}: waiting on an available worker" \
                   : "Blocked: waiting on an available worker"
      summary(text, @pipeline.status, label)
    end

    # --- R3/R4/R5/R6: actively working steps in the current phase ----------
    def working
      return unless @pipeline.running?

      active = active_step_runs
      return if active.empty? # a momentary lull -> fall through to default (R12)

      phase = current_phase
      label = humanize(phase.kind)

      text =
        case active.size
        when 1
          "#{label}: #{clause(*active.first)}"
        when 2
          "#{label}: #{clause(*active[0])} and #{clause(*active[1])}"
        else
          "#{label}: #{active.size} steps are running"
        end
      summary(text, "running", label)
    end

    # --- R10: exists but nothing has started -------------------------------
    def not_started
      return unless @pipeline.draft?

      summary("Not started", @pipeline.status, current_phase_label)
    end

    # --- R12: unconditional catch-all — truthful, never blank --------------
    def default
      label = current_phase_label
      text =
        if @pipeline.running? && label
          "Working in #{label}"
        elsif label
          "#{humanize(@pipeline.status)} in #{label}"
        else
          humanize(@pipeline.status)
        end
      summary(text, @pipeline.status, label)
    end

    # --- clause + wording helpers ------------------------------------------

    # "<role> is <doing>[, iteration <n>]" for one active step. The iteration is
    # shown only on the 2nd+ pass (R4), matching the step card's convention.
    def clause(step, run)
      suffix = run.iteration > 1 ? ", iteration #{run.iteration}" : ""
      "#{step.role} is #{doing(step, run)}#{suffix}"
    end

    def doing(step, run)
      message = run.progress.is_a?(Hash) ? run.progress["message"] : nil
      message.presence || TYPE_VERBS.fetch(step.step_type, "working")
    end

    def humanize(value) = value.to_s.humanize

    # --- state readers (in-memory; no queries on a preloaded tree) ----------

    # Active leased steps in the current phase, most salient first (running
    # before claimed, then most-recently updated).
    def active_step_runs
      phase = current_phase
      return [] unless phase

      pairs = []
      phase.workflows.each do |workflow|
        workflow.steps.each do |step|
          run = latest_run_of(step)
          pairs << [ step, run ] if run && ACTIVE_STATES.include?(run.state)
        end
      end
      pairs.sort_by { |_step, run| [ run.running? ? 0 : 1, -run.updated_at.to_f ] }
    end

    # The phase and step where an error stopped the pipeline, or nil. Prefers a
    # concretely failed run; falls back to a phase marked failed.
    def failed_context
      @pipeline.phases.each do |phase|
        phase.workflows.each do |workflow|
          workflow.steps.each do |step|
            step.step_runs.each do |run|
              return [ phase, step ] if run.failed?
            end
          end
        end
      end
      failed_phase = @pipeline.phases.detect(&:failed?)
      failed_phase ? [ failed_phase, nil ] : nil
    end

    def latest_run_of(step)
      step.step_runs.max_by { |run| [ run.iteration, run.attempt ] }
    end

    def current_phase
      kind = @pipeline.current_phase
      return nil unless kind

      @pipeline.phases.detect { |phase| phase.kind == kind }
    end

    def current_phase_label
      kind = @pipeline.current_phase
      kind && humanize(kind)
    end

    # Tone is always sourced from the shared StatusHelper::STATUS_TONES table —
    # the same table `status_badge` reads — so the summary dot and the pipeline
    # badge can never disagree about a state's color (F1).
    def summary(text, status, phase_label = current_phase_label)
      Summary.new(text: text, tone: tone(status), phase_label: phase_label)
    end

    def tone(status)
      StatusHelper::STATUS_TONES.fetch(status.to_s, :muted)
    end
  end
end
