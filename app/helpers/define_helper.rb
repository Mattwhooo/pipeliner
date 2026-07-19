module DefineHelper
  # The Define phase's clarifying questions, delivered by a worker as the
  # `open_questions` artifact on a StepRun#result. Returns the markdown of the
  # latest succeeded run that carries it, or nil when there are none yet.
  def define_open_questions(phase)
    run = latest_open_questions_run(phase)
    run && open_questions_artifact(run)
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
end
