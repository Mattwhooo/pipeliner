class Worker < ApplicationRecord
  has_many :step_runs, dependent: :nullify
  has_many :project_assessments, foreign_key: :ran_by_worker_id,
    dependent: :nullify, inverse_of: :ran_by_worker

  enum :status, { online: "online", draining: "draining", offline: "offline" }

  validates :public_id, presence: true, uniqueness: true
  validates :auth_token_digest, presence: true
  validates :concurrency, numericality: { greater_than: 0 }

  def supports_role?(role)
    supported_roles.include?(role)
  end
end
