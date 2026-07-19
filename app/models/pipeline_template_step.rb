class PipelineTemplateStep < ApplicationRecord
  belongs_to :pipeline_template
  belongs_to :step_template

  validates :phase, inclusion: { in: Phase::KINDS_IN_ORDER }
  validates :step_template_id,
    uniqueness: { scope: [ :pipeline_template_id, :phase ] }
end
