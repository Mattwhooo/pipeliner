class CreatePipelineRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :rework_events do |t|
      t.references :pipeline, null: false, foreign_key: true
      t.references :from_phase, null: false, foreign_key: { to_table: :phases }
      t.references :target_phase, null: false, foreign_key: { to_table: :phases }
      t.text :reason, null: false
      t.string :mode, null: false # automated | human
      t.jsonb :feedback, null: false, default: []
      t.string :raised_by, null: false, default: "agent" # agent | human
      t.datetime :resolved_at

      t.timestamps
    end

    create_table :approvals do |t|
      t.references :phase, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :decision, null: false # approve | send_back | abort
      t.references :target_phase, foreign_key: { to_table: :phases } # for send_back
      t.text :note

      t.timestamps
    end

    create_table :artifact_refs do |t|
      t.references :pipeline, null: false, foreign_key: true
      t.string :phase_kind, null: false
      t.string :workflow_slug
      t.string :step_slug
      t.string :name, null: false
      t.string :kind, null: false, default: "artifact" # artifact | repo
      t.string :path
      t.string :commit_sha

      t.timestamps
    end
    add_index :artifact_refs, [ :pipeline_id, :name ]

    create_table :archives do |t|
      t.references :pipeline, null: false, foreign_key: true
      t.string :s3_bucket, null: false
      t.string :s3_key, null: false
      t.bigint :bytes

      t.timestamps
    end

    create_table :manager_decisions do |t|
      t.references :phase, null: false, foreign_key: true
      t.integer :iteration, null: false
      t.string :decision, null: false # route_to | consensus | escalate
      t.jsonb :route_to, null: false, default: []
      t.text :rationale

      t.timestamps
    end

    create_table :project_assessments do |t|
      t.references :project, null: false, foreign_key: true
      t.string :status, null: false # passed | failed
      t.jsonb :findings, null: false, default: []
      t.references :ran_by_worker, foreign_key: { to_table: :workers }

      t.timestamps
    end
  end
end
