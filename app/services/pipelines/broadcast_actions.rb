module Pipelines
  # Live-updates the pipeline actions card (Review changes / Merge / Update from
  # main, plus any surfaced merge/update error) — the smallest DOM unit for the
  # post-finalization operations, keyed by dom_id(pipeline, :actions). Same
  # contract as StepRuns::BroadcastCard / Pipelines::BroadcastStatus: async
  # render, and the page always renders true state on load so a lost broadcast is
  # cosmetic.
  class BroadcastActions
    def self.call(pipeline)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(pipeline, :actions),
        partial: "pipelines/actions",
        locals: { pipeline: pipeline }
      )
    end
  end
end
