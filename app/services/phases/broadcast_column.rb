module Phases
  # Live-updates one phase column on the board (gate banners appearing, status
  # changes). Same contract as StepRuns::BroadcastCard: async render, pages
  # always show true state on load.
  class BroadcastColumn
    def self.call(phase)
      pipeline = phase.pipeline
      # Define is a full-width pre-phase panel; Plan/Build/Review are columns.
      # Both share the same target id (dom_id(phase, :column)).
      partial = phase.define_phase? ? "pipelines/define_panel" : "pipelines/phase_column"

      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(phase, :column),
        partial: partial,
        locals: { phase: phase, current_phase_kind: pipeline.current_phase }
      )
      Dashboard::Broadcast.call(pipeline: pipeline)
    end
  end
end
