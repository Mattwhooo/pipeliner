module Projects
  # Creates a project and makes the creating user its owner.
  # GitHub App wiring and the onboarding assessment dispatch come later —
  # env_status starts as "pending" until an assessment runs.
  class Create
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
      end

      Result.success(project)
    rescue ActiveRecord::RecordInvalid
      Result.failure(:invalid, record: project)
    end
  end
end
