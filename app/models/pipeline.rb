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

  validates :title, presence: true
  validates :public_id, presence: true, uniqueness: true
  validates :branch, presence: true, uniqueness: { scope: :project_id }
end
