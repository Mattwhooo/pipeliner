class StepEdge < ApplicationRecord
  belongs_to :workflow
  belongs_to :from_step, class_name: "Step"
  belongs_to :to_step, class_name: "Step"

  enum :kind, { depends_on: "depends_on", route_to: "route_to" }, suffix: true

  validates :from_step_id, uniqueness: { scope: [ :to_step_id, :kind ] }
end
