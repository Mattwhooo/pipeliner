class Phase < ApplicationRecord
  KINDS_IN_ORDER = %w[define plan build review].freeze

  belongs_to :pipeline
  has_many :workflows, dependent: :destroy
  has_many :approvals, dependent: :destroy
  has_many :manager_decisions, dependent: :destroy

  # Suffix avoids clashing with ActiveRecord's `build` class method:
  # define_phase?, build_phase?, Phase.review_phase, etc.
  enum :kind, { define: "define", plan: "plan", build: "build", review: "review" },
    suffix: :phase

  enum :status, {
    pending: "pending",
    running: "running",
    paused: "paused",           # Human-requested hold mid-loop (R2-R6).
    consensus: "consensus",
    approved: "approved",
    reworking: "reworking",
    # Consensus loop hit its max-iterations cap — parked for human guidance
    # (docs/execution-model.md "Convergence caps").
    awaiting_human: "awaiting_human",
    failed: "failed"
  }

  enum :gate_mode, { human: "human", auto: "auto" }, prefix: :gate

  validates :kind, uniqueness: { scope: :pipeline_id }
  validates :position, presence: true, uniqueness: { scope: :pipeline_id },
    inclusion: { in: 1..4 }

  # Any worker-executed step of this phase already has a live run (ready/
  # claimed/running) — used to gate pause/menu actions so a manual trigger
  # never overlaps the Manager's own dispatch or a previous menu action
  # (R29, R30).
  def any_step_active?
    workflows.flat_map(&:steps).any?(&:active_run?)
  end
end
