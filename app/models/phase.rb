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
    consensus: "consensus",
    approved: "approved",
    reworking: "reworking",
    failed: "failed"
  }

  enum :gate_mode, { human: "human", auto: "auto" }, prefix: :gate

  validates :kind, uniqueness: { scope: :pipeline_id }
  validates :position, presence: true, uniqueness: { scope: :pipeline_id },
    inclusion: { in: 1..4 }
end
