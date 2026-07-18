module Pipelines
  # Creates a pipeline with its four fixed phases (Define → Plan → Build →
  # Review) and its dedicated branch name. Cutting the actual git branch and
  # opening the PR happen in the GitHub integration (later); until then the
  # pipeline stays in "draft".
  class Create
    PHASE_KINDS = Phase::KINDS_IN_ORDER

    def self.call(project:, title:, initial_prompt: nil)
      new(project:, title:, initial_prompt:).call
    end

    def initialize(project:, title:, initial_prompt:)
      @project = project
      @title = title
      @initial_prompt = initial_prompt
    end

    def call
      public_id = generate_public_id
      pipeline = @project.pipelines.new(
        title: @title,
        initial_prompt: @initial_prompt,
        public_id: public_id,
        branch: "pipeliner/#{public_id}",
        status: "draft",
        current_phase: "define"
      )

      ApplicationRecord.transaction do
        pipeline.save!
        PHASE_KINDS.each_with_index do |kind, index|
          pipeline.phases.create!(kind: kind, position: index + 1)
        end
      end

      Result.success(pipeline)
    rescue ActiveRecord::RecordInvalid
      Result.failure(:invalid, record: pipeline)
    end

    private

    def generate_public_id
      loop do
        candidate = "pl_#{SecureRandom.alphanumeric(8).downcase}"
        break candidate unless Pipeline.exists?(public_id: candidate)
      end
    end
  end
end
