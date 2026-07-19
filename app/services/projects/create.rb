module Projects
  # Creates a project, makes the creating user its owner, and seeds its
  # pipeline template (the pinned per-phase composition every pipeline of this
  # project starts from). GitHub App wiring and the onboarding assessment
  # dispatch come later — env_status starts as "pending" until an assessment
  # runs.
  class Create
    # The default pinned composition, mirroring the software pack's required
    # steps per phase. Missing templates (bare DBs, tests) are skipped.
    DEFAULT_PINNED = {
      "define" => [ "Requirements Writer", "Clarifying Questions Writer",
                    "Requirements Completeness Critic" ],
      "plan" => [ "Workflow Composer", "Design Writer", "Guide Alignment Critic",
                  "Design Coverage Critic" ],
      "build" => [ "Implementer", "Test Critic" ],
      "review" => [ "Requirements Conformance Critic", "Review Report Writer" ]
    }.freeze

    def self.call(owner:, attributes:)
      new(owner:, attributes:).call
    end

    def initialize(owner:, attributes:)
      @owner = owner
      @attributes = attributes
    end

    def call
      project = Project.new(@attributes)

      ApplicationRecord.transaction do
        project.save!
        project.memberships.create!(user: @owner, role: "owner")
        seed_pipeline_template(project)
      end

      Result.success(project)
    rescue ActiveRecord::RecordInvalid
      Result.failure(:invalid, record: project)
    end

    private

    def seed_pipeline_template(project)
      template = project.create_pipeline_template!(allow_manager_additions: true)
      DEFAULT_PINNED.each do |phase, names|
        names.each_with_index do |name, index|
          step_template = StepTemplate.available_to(project).find_by(name: name)
          next unless step_template

          template.pipeline_template_steps.create!(
            step_template: step_template, phase: phase, position: index + 1
          )
        end
      end
    end
  end
end
