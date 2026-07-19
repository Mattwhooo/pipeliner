class ManagerDecision < ApplicationRecord
  belongs_to :phase

  enum :decision, {
    route_to: "route_to",
    consensus: "consensus",
    escalate: "escalate",
    # "Repeat from the Beginning" converged and returned to the paused menu
    # (Phases::ManagerTick#settle_restart).
    restart_complete: "restart_complete"
  }, suffix: true

  validates :iteration, presence: true, numericality: { greater_than: 0 }
end
