class CreatePipelineTemplates < ActiveRecord::Migration[8.1]
  def change
    # Per-project pipeline composition: the steps every pipeline of this
    # project always gets (pinned, per phase), plus whether the Manager /
    # Workflow Composer may add further steps beyond the pinned set.
    create_table :pipeline_templates do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.boolean :allow_manager_additions, null: false, default: true

      t.timestamps
    end

    create_table :pipeline_template_steps do |t|
      t.references :pipeline_template, null: false, foreign_key: true
      t.references :step_template, null: false, foreign_key: true
      t.string :phase, null: false # define | plan | build | review
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :pipeline_template_steps,
      [ :pipeline_template_id, :step_template_id, :phase ],
      unique: true, name: "index_pipeline_template_steps_uniqueness"
  end
end
