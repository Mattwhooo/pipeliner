class Approval < ApplicationRecord
  belongs_to :phase
  belongs_to :user
  belongs_to :target_phase, class_name: "Phase", optional: true # for send_back

  enum :decision, { approve: "approve", send_back: "send_back", abort: "abort" },
    suffix: true

  validates :target_phase, presence: true, if: :send_back_decision?
end
