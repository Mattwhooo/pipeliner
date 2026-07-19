module Pipelines
  # Live-updates a pipeline's plain-language status summary (the smallest DOM
  # unit for "what is happening right now" — guides/ui-style-guide.md). Mirrors
  # StepRuns::BroadcastCard: rendering happens async in a job that reloads the
  # pipeline, so each broadcast paints freshly-derived state from the database at
  # render time. Two consequences:
  #   - A lost or racing broadcast is cosmetic, never wrong — the page also
  #     renders true state on load (R15).
  #   - A late-arriving broadcast still renders the *actual latest* state, so a
  #     newer state is never overwritten by an older event (R16).
  class BroadcastStatus
    def self.call(pipeline)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(pipeline, :summary),
        partial: "pipelines/status_summary",
        locals: { pipeline: pipeline, compact: false }
      )
    end
  end
end
