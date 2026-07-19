module Phases
  # A single-step re-run triggered from the paused menu. The target step is
  # resolved by the artifact it's declared to write (Step#outputs), not by
  # slug/name — a project's pipeline_template can rename or reorder Define's
  # steps (app/services/pipelines/create.rb), so only artifact identity is a
  # stable contract (docs/artifact-schema.md).
  class RerunMenuStep
    ARTIFACTS = %w[discovery_notes open_questions].freeze

    def self.call(phase:, artifact:)
      new(phase:, artifact:).call
    end

    def initialize(phase:, artifact:)
      @phase = phase
      @artifact = artifact.to_s
    end

    def call
      return Result.failure(:invalid_artifact) unless @artifact.in?(ARTIFACTS)
      return Result.failure(:not_paused, record: @phase) unless @phase.paused?
      return Result.failure(:busy, record: @phase) if @phase.any_step_active?

      step = target_step
      return Result.failure(:no_target, record: @phase) if step.nil?

      run = step.step_runs.create!(
        state: "ready",
        iteration: (step.step_runs.maximum(:iteration) || 0) + 1,
        required_role: step.role
      )

      StepRuns::BroadcastCard.call(run)
      BroadcastColumn.call(@phase)
      Result.success(run)
    rescue ActiveRecord::RecordInvalid => e
      Result.failure(:invalid, record: e.record)
    end

    private

    def target_step
      @phase.workflows.flat_map(&:steps)
        .find { |s| s.worker_executed? && declares_artifact?(s) }
    end

    def declares_artifact?(step)
      Array(step.outputs).any? { |output| output["artifact"] == @artifact }
    end
  end
end
