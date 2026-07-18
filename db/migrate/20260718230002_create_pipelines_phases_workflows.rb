class CreatePipelinesPhasesWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :pipelines do |t|
      t.references :project, null: false, foreign_key: true
      t.string :title, null: false
      t.string :public_id, null: false
      t.string :branch, null: false
      t.integer :pr_number
      t.string :pr_url
      t.string :status, null: false, default: "draft"
      t.string :current_phase, null: false, default: "define"
      t.jsonb :config, null: false, default: {}
      t.text :initial_prompt

      t.timestamps
    end
    add_index :pipelines, :public_id, unique: true
    add_index :pipelines, [ :project_id, :branch ], unique: true
    add_index :pipelines, [ :project_id, :status ]

    create_table :phases do |t|
      t.references :pipeline, null: false, foreign_key: true
      t.string :kind, null: false
      t.integer :position, null: false
      t.string :status, null: false, default: "pending"
      t.string :gate_mode, null: false, default: "human"
      t.integer :rework_count, null: false, default: 0

      t.timestamps
    end
    add_index :phases, [ :pipeline_id, :kind ], unique: true
    add_index :phases, [ :pipeline_id, :position ], unique: true

    create_table :workflows do |t|
      t.references :phase, null: false, foreign_key: true
      t.string :slug, null: false
      t.integer :max_parallel, null: false, default: 4
      t.integer :max_iterations, null: false, default: 10
      t.string :status, null: false, default: "pending"
      t.jsonb :shared_paths, null: false, default: []
      t.datetime :compiled_at

      t.timestamps
    end
    add_index :workflows, [ :phase_id, :slug ], unique: true
  end
end
