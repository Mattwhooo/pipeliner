class Workflow < ApplicationRecord
  belongs_to :phase
  has_many :steps, -> { order(:position) }, dependent: :destroy, inverse_of: :workflow
  has_many :step_edges, dependent: :destroy

  enum :status, {
    pending: "pending",
    running: "running",
    converged: "converged",
    failed: "failed"
  }

  validates :slug, presence: true, uniqueness: { scope: :phase_id }
  validates :max_parallel, numericality: { greater_than: 0 }
  validates :max_iterations, numericality: { greater_than: 0 }
end
