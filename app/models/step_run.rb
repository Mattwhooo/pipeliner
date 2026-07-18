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
    stuck: "stuck"
  }

  validates :iteration, numericality: { greater_than: 0 }
  validates :attempt, numericality: { greater_than: 0 }
  validates :required_role, presence: true

  scope :leased, -> { where(state: [ :claimed, :running ]) }
  scope :lease_expired, -> { leased.where(lease_expires_at: ...Time.current) }

  def lease_expired?
    lease_expires_at.present? && lease_expires_at.past?
  end
end
