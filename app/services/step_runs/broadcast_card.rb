module StepRuns
  # Live-updates one step card on the pipeline board (smallest DOM unit —
  # guides/ui-style-guide.md). Rendering happens async in a job, which reloads
  # the step's latest state; pages always render true state on load, so a lost
  # broadcast is cosmetic, never correctness.
  class BroadcastCard
    # `dashboard: false` skips the per-member dashboard fan-out (row + summary
    # + fleet health recompute) for callers that aren't a state-changing
    # transition — e.g. RecordProgress fires on every worker progress tick,
    # which would otherwise re-run that aggregation many times per second.
    def self.call(step_run, dashboard: true)
      step = step_run.step
      pipeline = step.workflow.phase.pipeline

      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(step, :card),
        partial: "pipelines/step_card",
        locals: { step: step }
      )
      Dashboard::Broadcast.call(pipeline: pipeline) if dashboard
    end
  end
end
