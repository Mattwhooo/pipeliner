class Pipeline < ApplicationRecord
  belongs_to :project
  has_many :phases, -> { order(:position) }, dependent: :destroy, inverse_of: :pipeline
  has_many :rework_events, dependent: :destroy
  has_many :artifact_refs, dependent: :destroy
  has_many :archives, dependent: :destroy

  enum :status, {
    draft: "draft",
    running: "running",
    awaiting_human: "awaiting_human",
    blocked: "blocked",
    stuck: "stuck",
    completed: "completed",
    aborted: "aborted"
  }

  enum :current_phase, {
    define: "define",
    plan: "plan",
    build: "build",
    review: "review"
  }, prefix: :in

  # Preloads the whole board tree so the status summary derives with zero extra
  # queries on show/index (Pipelines::StatusSummary reads it Ruby-side).
  scope :with_board, -> {
    includes(phases: { workflows: { steps: { step_runs: :worker } } })
  }

  validates :title, presence: true
  validates :public_id, presence: true, uniqueness: true
  validates :branch, presence: true, uniqueness: { scope: :project_id }
end
