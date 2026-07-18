class Step < ApplicationRecord
  # Step types pulled and executed by external Workers (vs. controller types
  # run by the control plane: manager, gate).
  WORKER_EXECUTED_TYPES = %w[planner builder critic].freeze

  belongs_to :workflow
  belongs_to :step_template, optional: true # provenance
  has_many :step_runs, dependent: :destroy
  has_many :outgoing_edges, class_name: "StepEdge", foreign_key: :from_step_id,
    dependent: :destroy, inverse_of: :from_step
  has_many :incoming_edges, class_name: "StepEdge", foreign_key: :to_step_id,
    dependent: :destroy, inverse_of: :to_step

  enum :step_type, {
    planner: "planner",
    builder: "builder",
    critic: "critic",
    manager: "manager",
    gate: "gate"
  }, prefix: :type

  validates :slug, presence: true, uniqueness: { scope: :workflow_id }
  # Role is the worker-matching label — required for anything a worker pulls.
  validates :role, presence: true, if: :worker_executed?

  def worker_executed?
    step_type.in?(WORKER_EXECUTED_TYPES)
  end

  def latest_run
    step_runs.order(:iteration, :attempt).last
  end
end
