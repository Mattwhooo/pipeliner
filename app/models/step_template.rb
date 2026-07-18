class StepTemplate < ApplicationRecord
  belongs_to :project, optional: true # nil = global/shared template

  enum :step_type, {
    planner: "planner",
    builder: "builder",
    critic: "critic",
    manager: "manager",
    gate: "gate"
  }, prefix: :type

  enum :requirement, { required: "required", conditional: "conditional" }, suffix: true

  validates :name, presence: true, uniqueness: { scope: :project_id }

  scope :global, -> { where(project_id: nil) }
  scope :available_to, ->(project) { where(project_id: [ nil, project.id ]) }
end
