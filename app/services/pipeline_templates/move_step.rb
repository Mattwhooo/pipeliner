module PipelineTemplates
  # Swaps a pinned entry with its neighbor within the same phase (reordering).
  class MoveStep
    def self.call(entry:, direction:)
      new(entry:, direction:).call
    end

    def initialize(entry:, direction:)
      @entry = entry
      @direction = direction.to_s
    end

    def call
      return Result.failure(:invalid_direction) unless @direction.in?(%w[up down])

      siblings = @entry.pipeline_template.entries_for(@entry.phase).order(:position).to_a
      index = siblings.index(@entry)
      neighbor_index = @direction == "up" ? index - 1 : index + 1
      return Result.failure(:at_edge) if neighbor_index.negative? || neighbor_index >= siblings.size

      neighbor = siblings[neighbor_index]
      ApplicationRecord.transaction do
        @entry.position, neighbor.position = neighbor.position, @entry.position
        @entry.save!
        neighbor.save!
      end

      Result.success(@entry)
    end
  end
end
