class CreateStepsAndRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :step_templates do |t|
      t.references :project, foreign_key: true # null = global/shared template
      t.string :name, null: false
      t.string :step_type, null: false
      t.string :role
      t.text :system_prompt
      t.jsonb :default_inputs, null: false, default: []
      t.jsonb :default_outputs, null: false, default: []
      t.string :requirement, null: false, default: "conditional"
      t.jsonb :default_scope

      t.timestamps
    end
    add_index :step_templates, [ :project_id, :name ], unique: true

    create_table :steps do |t|
      t.references :workflow, null: false, foreign_key: true
      t.references :step_template, foreign_key: true # provenance, optional
      t.string :slug, null: false
      t.string :step_type, null: false
      t.string :role
      t.text :system_prompt
      t.jsonb :inputs, null: false, default: []
      t.jsonb :outputs, null: false, default: []
      t.jsonb :scope
      t.jsonb :fan_out
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :steps, [ :workflow_id, :slug ], unique: true

    create_table :step_edges do |t|
      t.references :workflow, null: false, foreign_key: true
      t.references :from_step, null: false, foreign_key: { to_table: :steps }
      t.references :to_step, null: false, foreign_key: { to_table: :steps }
      t.string :kind, null: false # depends_on | route_to

      t.timestamps
    end
    add_index :step_edges, [ :from_step_id, :to_step_id, :kind ], unique: true

    create_table :step_runs do |t|
      t.references :step, null: false, foreign_key: true
      t.integer :iteration, null: false, default: 1
      t.integer :attempt, null: false, default: 1
      t.string :shard_key
      t.string :state, null: false, default: "ready"
      t.string :required_role, null: false
      t.references :worker, foreign_key: true # current claimant
      t.datetime :lease_expires_at
      t.datetime :last_heartbeat_at
      t.jsonb :progress
      t.jsonb :result
      t.jsonb :verdict
      t.string :commit_sha
      t.string :step_branch
      t.string :epoch
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
    # Claiming path: ready runs by role (SKIP LOCKED query).
    add_index :step_runs, [ :state, :required_role ]
    # Reclaim sweeper.
    add_index :step_runs, :lease_expires_at
    # One run per (step, iteration, attempt); fan-out shards are distinguished
    # by shard_key. Two partial uniques because NULL != NULL in Postgres.
    add_index :step_runs, [ :step_id, :iteration, :attempt ],
      unique: true, where: "shard_key IS NULL",
      name: "index_step_runs_unique_without_shard"
    add_index :step_runs, [ :step_id, :iteration, :attempt, :shard_key ],
      unique: true, where: "shard_key IS NOT NULL",
      name: "index_step_runs_unique_with_shard"
  end
end
