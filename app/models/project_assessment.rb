class ProjectAssessment < ApplicationRecord
  belongs_to :project
  belongs_to :ran_by_worker, class_name: "Worker", optional: true

  enum :status, { passed: "passed", failed: "failed" }, suffix: true
end
