module Phases
  # Live-updates one phase column on the board (gate banners appearing, status
  # changes). Same contract as StepRuns::BroadcastCard: async render, pages
  # always show true state on load.
  class BroadcastColumn
    def self.call(phase)
      pipeline = phase.pipeline

      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(phase, :column),
        partial: "pipelines/phase_column",
        locals: { phase: phase, current_phase_kind: pipeline.current_phase }
      )
    end
  end
end
