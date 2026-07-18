class ManagerDecision < ApplicationRecord
  belongs_to :phase

  enum :decision, { route_to: "route_to", consensus: "consensus", escalate: "escalate" },
    suffix: true

  validates :iteration, presence: true, numericality: { greater_than: 0 }
end
