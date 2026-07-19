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
    gate: "gate",
    # A step a HUMAN executes in the UI (the Define phase's Human Feedback
    # step). The Manager dispatches it into an `awaiting_input` run the product
    # owns; no worker ever claims it. See Phases::SubmitHumanFeedback and
    # docs/execution-model.md — "Human Feedback step".
    human: "human"
  }, prefix: :type

  validates :slug, presence: true, uniqueness: { scope: :workflow_id }
  # Role is the worker-matching label — required for anything a worker pulls.
  # Human steps aren't claimed, but still carry a role ("human") so required_role
  # (NOT NULL on step_runs) has a value; validate it likewise.
  validates :role, presence: true, if: -> { worker_executed? || type_human? }

  def worker_executed?
    step_type.in?(WORKER_EXECUTED_TYPES)
  end

  def latest_run
    step_runs.order(:iteration, :attempt).last
  end

  # A run is in flight (queued, leased, parked stuck, or awaiting a human's
  # input) — the step already has live work; dispatching another would
  # duplicate it.
  def active_run?
    step_runs.where(state: %w[ready claimed running stuck awaiting_input]).exists?
  end

  # depends_on predecessors that a Worker actually executes (planner/builder/
  # critic). Ordering edges to manager/gate steps don't gate dispatch.
  def worker_predecessors
    incoming_edges.where(kind: "depends_on").map(&:from_step).select(&:worker_executed?)
  end

  # route_to targets a critic hands feedback to on a needs_work verdict.
  def route_targets
    outgoing_edges.where(kind: "route_to").map(&:to_step)
  end
end
