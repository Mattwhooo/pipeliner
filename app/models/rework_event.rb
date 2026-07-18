class ReworkEvent < ApplicationRecord
  belongs_to :pipeline
  belongs_to :from_phase, class_name: "Phase"
  belongs_to :target_phase, class_name: "Phase"

  enum :mode, { automated: "automated", human: "human" }, suffix: true
  enum :raised_by, { agent: "agent", human: "human" }, prefix: :raised_by

  validates :reason, presence: true

  scope :unresolved, -> { where(resolved_at: nil) }
end
