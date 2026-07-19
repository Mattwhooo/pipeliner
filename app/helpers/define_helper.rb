module DefineHelper
  # The Define phase's clarifying questions, delivered by a worker as the
  # `open_questions` artifact on a StepRun#result. Returns the markdown of the
  # latest succeeded run that carries it, or nil when there are none yet.
  def define_open_questions(phase)
    define_artifact(phase, "open_questions")
  end

  def define_discovery_notes(phase)
    define_artifact(phase, "discovery_notes")
  end

  # Requirements Writer's output — surfaced so a completed "Repeat from the
  # Beginning" (which regenerates all three Define artifacts) shows its fresh
  # business_requirements before the paused menu, not just discovery notes and
  # open questions.
  def define_business_requirements(phase)
    define_artifact(phase, "business_requirements")
  end

  # The most recent failed/stuck run across Define's steps — while paused, the
  # only steps that ever run are ones the human just triggered from the menu,
  # so this is always "my re-run failed," never Manager-triggered noise (R26).
  def define_menu_failure(phase)
    run = phase.workflows.flat_map(&:steps).filter_map(&:latest_run)
      .select { |r| r.state.in?(%w[failed stuck]) }
      .max_by { |r| [ r.iteration, r.attempt, r.id ] }
    run && run.result.is_a?(Hash) ? run.result["summary"].presence : nil
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

  def define_artifact(phase, name)
    run = latest_artifact_run(phase, name)
    run && artifact_value(run, name)
  end

  def latest_artifact_run(phase, name)
    phase.workflows.flat_map(&:steps).flat_map(&:step_runs)
      .select { |run| run.succeeded? && artifact_value(run, name).present? }
      .max_by { |run| [ run.iteration, run.attempt, run.id ] }
  end

  def artifact_value(run, name)
    return nil unless run.result.is_a?(Hash)

    artifacts = run.result["artifacts"]
    artifacts.is_a?(Hash) ? artifacts[name].presence : nil
  end

  def latest_structured_questions_run(phase)
    phase.workflows.flat_map(&:steps).flat_map(&:step_runs)
      .select { |run| run.succeeded? && run.result.is_a?(Hash) && run.result.dig("artifacts", "open_questions_structured").present? }
      .max_by { |run| [ run.iteration, run.attempt, run.id ] }
  end
end
