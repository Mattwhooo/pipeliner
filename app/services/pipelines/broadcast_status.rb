module Pipelines
  # Live-updates one pipeline's status summary on the board — the smallest DOM
  # unit for "what is happening right now", separate from the per-step cards
  # (guides/ui-style-guide.md; backend-guide "Broadcasts happen from services,
  # after commit, target the smallest partial keyed by dom_id"). Mirrors
  # StepRuns::BroadcastCard.
  #
  # Rendering happens async in a job that reloads the pipeline by GlobalID, so
  # every broadcast paints freshly-derived state: a lost or racing broadcast is
  # cosmetic (pages also render true state on load, R15), and a late event still
  # renders the actual latest state, so a newer state is never overwritten by an
  # older one (R16).
  class BroadcastStatus
    def self.call(pipeline)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(pipeline, :summary),
        partial: "pipelines/status_summary",
        locals: { pipeline: pipeline }
      )
    end
  end
end
