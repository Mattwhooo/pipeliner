module DefineHelper
  # The Define phase's clarifying questions, delivered by a worker as the
  # `open_questions` artifact on a StepRun#result. Returns the markdown of the
  # latest succeeded run that carries it, or nil when there are none yet.
  def define_open_questions(phase)
    run = latest_open_questions_run(phase)
    run && open_questions_artifact(run)
  end

  # Structured [{ "question" => ..., "default" => ... }, ...] for the answer
  # modal. Returns [] (never raises) when the artifact is missing or
  # malformed — e.g. a phase whose run predates this artifact — so the modal
  # simply doesn't offer the action, rather than the page erroring.
  def define_open_questions_structured(phase)
    run = latest_structured_questions_run(phase)
    return [] unless run

    data = run.result.dig("artifacts", "open_questions_structured")
    parsed = data.is_a?(String) ? JSON.parse(data) : data
    Array(parsed).select { |q| q.is_a?(Hash) && q["question"].present? }
  rescue JSON::ParserError
    []
  end

  private

  def latest_open_questions_run(phase)
    phase.workflows.flat_map(&:steps).flat_map(&:step_runs)
      .select { |run| run.succeeded? && open_questions_artifact(run).present? }
      .max_by { |run| [ run.iteration, run.attempt, run.id ] }
  end

  def open_questions_artifact(run)
    return nil unless run.result.is_a?(Hash)

    artifacts = run.result["artifacts"]
    artifacts.is_a?(Hash) ? artifacts["open_questions"].presence : nil
  end

  def latest_structured_questions_run(phase)
    phase.workflows.flat_map(&:steps).flat_map(&:step_runs)
      .select { |run| run.succeeded? && run.result.is_a?(Hash) && run.result.dig("artifacts", "open_questions_structured").present? }
      .max_by { |run| [ run.iteration, run.attempt, run.id ] }
  end
end
