class StepRun < ApplicationRecord
  belongs_to :step
  belongs_to :worker, optional: true # current claimant while leased
  has_many :step_tokens, dependent: :destroy

  enum :state, {
    ready: "ready",
    claimed: "claimed",
    running: "running",
    succeeded: "succeeded",
    failed: "failed",
    stuck: "stuck",
    # A human-executed step (Step#type_human?) dispatched by the Manager and
    # waiting for the human to submit it in the UI. Deliberately NOT "ready": no
    # worker may claim it (StepRuns::ClaimableFor filters state: "ready") and the
    # sweeper leaves it alone (it neither leases nor lease-expires).
    awaiting_input: "awaiting_input"
  }

  validates :iteration, numericality: { greater_than: 0 }
  validates :attempt, numericality: { greater_than: 0 }
  validates :required_role, presence: true

  scope :leased, -> { where(state: [ :claimed, :running ]) }
  scope :lease_expired, -> { leased.where(lease_expires_at: ...Time.current) }

  def lease_expired?
    lease_expires_at.present? && lease_expires_at.past?
  end

  # True once the control plane has merged this run's step branch into the
  # pipeline branch (Pipelines::MergeStepBranch). A succeeded run only counts as
  # a satisfied predecessor / toward consensus once merged — otherwise later
  # steps' worktrees wouldn't contain this step's artifacts.
  def merged?
    merged_at.present?
  end

  # The critic's structured verdict value ("pass" | "needs_work" |
  # "not_applicable"), read from the verdict.json mirror. Nil for non-critics.
  def verdict_status
    verdict.is_a?(Hash) ? verdict["verdict"] : nil
  end

  # Structured findings the critic emitted (routed to a re-run as feedback).
  def findings
    verdict.is_a?(Hash) ? Array(verdict["findings"]) : []
  end
end
