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
    merged: "merged",
    aborted: "aborted"
  }

  enum :current_phase, {
    define: "define",
    plan: "plan",
    build: "build",
    review: "review"
  }, prefix: :in

  validates :title, presence: true
  validates :public_id, presence: true, uniqueness: true
  validates :branch, presence: true, uniqueness: { scope: :project_id }

  # Preloads the full board tree so the live status summary
  # (Pipelines::StatusSummary) derives with zero extra queries on both the
  # detail page and the list.
  scope :with_board, -> {
    includes(phases: { workflows: { steps: { step_runs: :worker } } })
  }
end
