module StepRuns
  # Live-updates one step card on the pipeline board (smallest DOM unit —
  # guides/ui-style-guide.md). Rendering happens async in a job, which reloads
  # the step's latest state; pages always render true state on load, so a lost
  # broadcast is cosmetic, never correctness.
  class BroadcastCard
    def self.call(step_run)
      step = step_run.step
      pipeline = step.workflow.phase.pipeline

      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(step, :card),
        partial: "pipelines/step_card",
        locals: { step: step }
      )
      Dashboard::Broadcast.call(pipeline: pipeline)
    end
  end
end
