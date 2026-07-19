class PipelineTemplate < ApplicationRecord
  belongs_to :project
  has_many :pipeline_template_steps, -> { order(:phase, :position) },
    dependent: :destroy, inverse_of: :pipeline_template
  has_many :step_templates, through: :pipeline_template_steps

  validates :project_id, uniqueness: true

  # Pinned entries for one phase, in composition order.
  def entries_for(phase_kind)
    pipeline_template_steps.where(phase: phase_kind.to_s)
  end
end
