class AddPhaseToStepTemplates < ActiveRecord::Migration[8.1]
  def change
    # Which phase a template belongs to (define|plan|build|review). Null = any
    # phase (general-purpose templates like a test runner).
    add_column :step_templates, :phase, :string
    add_index :step_templates, :phase
  end
end
