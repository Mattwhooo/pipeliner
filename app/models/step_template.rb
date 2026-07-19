class StepTemplate < ApplicationRecord
  belongs_to :project, optional: true # nil = global/shared template

  enum :step_type, {
    planner: "planner",
    builder: "builder",
    critic: "critic",
    manager: "manager",
    gate: "gate",
    human: "human" # executed by a human in the UI (see Step#type_human?)
  }, prefix: :type

  enum :requirement, { required: "required", conditional: "conditional" }, suffix: true

  validates :name, presence: true, uniqueness: { scope: :project_id }
  validates :phase, inclusion: { in: Phase::KINDS_IN_ORDER }, allow_nil: true

  scope :global, -> { where(project_id: nil) }
  scope :available_to, ->(project) { where(project_id: [ nil, project.id ]) }
  # Templates usable in a given phase: tagged for it, or untagged (any phase).
  scope :for_phase, ->(kind) { where(phase: [ kind.to_s, nil ]) }
end
