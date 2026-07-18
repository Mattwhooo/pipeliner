# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_18_230005) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "approvals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.text "note"
    t.bigint "phase_id", null: false
    t.bigint "target_phase_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["phase_id"], name: "index_approvals_on_phase_id"
    t.index ["target_phase_id"], name: "index_approvals_on_target_phase_id"
    t.index ["user_id"], name: "index_approvals_on_user_id"
  end

  create_table "archives", force: :cascade do |t|
    t.bigint "bytes"
    t.datetime "created_at", null: false
    t.bigint "pipeline_id", null: false
    t.string "s3_bucket", null: false
    t.string "s3_key", null: false
    t.datetime "updated_at", null: false
    t.index ["pipeline_id"], name: "index_archives_on_pipeline_id"
  end

  create_table "artifact_refs", force: :cascade do |t|
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.string "kind", default: "artifact", null: false
    t.string "name", null: false
    t.string "path"
    t.string "phase_kind", null: false
    t.bigint "pipeline_id", null: false
    t.string "step_slug"
    t.datetime "updated_at", null: false
    t.string "workflow_slug"
    t.index ["pipeline_id", "name"], name: "index_artifact_refs_on_pipeline_id_and_name"
    t.index ["pipeline_id"], name: "index_artifact_refs_on_pipeline_id"
  end

  create_table "manager_decisions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.integer "iteration", null: false
    t.bigint "phase_id", null: false
    t.text "rationale"
    t.jsonb "route_to", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["phase_id"], name: "index_manager_decisions_on_phase_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["project_id"], name: "index_memberships_on_project_id"
    t.index ["user_id", "project_id"], name: "index_memberships_on_user_id_and_project_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "phases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "gate_mode", default: "human", null: false
    t.string "kind", null: false
    t.bigint "pipeline_id", null: false
    t.integer "position", null: false
    t.integer "rework_count", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["pipeline_id", "kind"], name: "index_phases_on_pipeline_id_and_kind", unique: true
    t.index ["pipeline_id", "position"], name: "index_phases_on_pipeline_id_and_position", unique: true
    t.index ["pipeline_id"], name: "index_phases_on_pipeline_id"
  end

  create_table "pipelines", force: :cascade do |t|
    t.string "branch", null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "current_phase", default: "define", null: false
    t.text "initial_prompt"
    t.integer "pr_number"
    t.string "pr_url"
    t.bigint "project_id", null: false
    t.string "public_id", null: false
    t.string "status", default: "draft", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "branch"], name: "index_pipelines_on_project_id_and_branch", unique: true
    t.index ["project_id", "status"], name: "index_pipelines_on_project_id_and_status"
    t.index ["project_id"], name: "index_pipelines_on_project_id"
    t.index ["public_id"], name: "index_pipelines_on_public_id", unique: true
  end

  create_table "project_assessments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "findings", default: [], null: false
    t.bigint "project_id", null: false
    t.bigint "ran_by_worker_id"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_project_assessments_on_project_id"
    t.index ["ran_by_worker_id"], name: "index_project_assessments_on_ran_by_worker_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main", null: false
    t.string "env_status", default: "pending", null: false
    t.string "github_app_installation_id"
    t.string "name", null: false
    t.string "project_type", default: "software", null: false
    t.string "repo_url", null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["repo_url"], name: "index_projects_on_repo_url", unique: true
  end

  create_table "rework_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "feedback", default: [], null: false
    t.bigint "from_phase_id", null: false
    t.string "mode", null: false
    t.bigint "pipeline_id", null: false
    t.string "raised_by", default: "agent", null: false
    t.text "reason", null: false
    t.datetime "resolved_at"
    t.bigint "target_phase_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_phase_id"], name: "index_rework_events_on_from_phase_id"
    t.index ["pipeline_id"], name: "index_rework_events_on_pipeline_id"
    t.index ["target_phase_id"], name: "index_rework_events_on_target_phase_id"
  end

  create_table "step_edges", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "from_step_id", null: false
    t.string "kind", null: false
    t.bigint "to_step_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "workflow_id", null: false
    t.index ["from_step_id", "to_step_id", "kind"], name: "index_step_edges_on_from_step_id_and_to_step_id_and_kind", unique: true
    t.index ["from_step_id"], name: "index_step_edges_on_from_step_id"
    t.index ["to_step_id"], name: "index_step_edges_on_to_step_id"
    t.index ["workflow_id"], name: "index_step_edges_on_workflow_id"
  end

  create_table "step_runs", force: :cascade do |t|
    t.integer "attempt", default: 1, null: false
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.string "epoch"
    t.datetime "finished_at"
    t.integer "iteration", default: 1, null: false
    t.datetime "last_heartbeat_at"
    t.datetime "lease_expires_at"
    t.jsonb "progress"
    t.string "required_role", null: false
    t.jsonb "result"
    t.string "shard_key"
    t.datetime "started_at"
    t.string "state", default: "ready", null: false
    t.string "step_branch"
    t.bigint "step_id", null: false
    t.datetime "updated_at", null: false
    t.jsonb "verdict"
    t.bigint "worker_id"
    t.index ["lease_expires_at"], name: "index_step_runs_on_lease_expires_at"
    t.index ["state", "required_role"], name: "index_step_runs_on_state_and_required_role"
    t.index ["step_id", "iteration", "attempt", "shard_key"], name: "index_step_runs_unique_with_shard", unique: true, where: "(shard_key IS NOT NULL)"
    t.index ["step_id", "iteration", "attempt"], name: "index_step_runs_unique_without_shard", unique: true, where: "(shard_key IS NULL)"
    t.index ["step_id"], name: "index_step_runs_on_step_id"
    t.index ["worker_id"], name: "index_step_runs_on_worker_id"
  end

  create_table "step_templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "default_inputs", default: [], null: false
    t.jsonb "default_outputs", default: [], null: false
    t.jsonb "default_scope"
    t.string "name", null: false
    t.bigint "project_id"
    t.string "requirement", default: "conditional", null: false
    t.string "role"
    t.string "step_type", null: false
    t.text "system_prompt"
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_step_templates_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_step_templates_on_project_id"
  end

  create_table "step_tokens", force: :cascade do |t|
    t.string "allowed_ref"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.jsonb "scopes", default: [], null: false
    t.bigint "step_run_id", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["step_run_id"], name: "index_step_tokens_on_step_run_id"
    t.index ["token_digest"], name: "index_step_tokens_on_token_digest", unique: true
  end

  create_table "steps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "fan_out"
    t.jsonb "inputs", default: [], null: false
    t.jsonb "outputs", default: [], null: false
    t.integer "position", default: 0, null: false
    t.string "role"
    t.jsonb "scope"
    t.string "slug", null: false
    t.bigint "step_template_id"
    t.string "step_type", null: false
    t.text "system_prompt"
    t.datetime "updated_at", null: false
    t.bigint "workflow_id", null: false
    t.index ["step_template_id"], name: "index_steps_on_step_template_id"
    t.index ["workflow_id", "slug"], name: "index_steps_on_workflow_id_and_slug", unique: true
    t.index ["workflow_id"], name: "index_steps_on_workflow_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "workers", force: :cascade do |t|
    t.string "auth_token_digest", null: false
    t.string "backend"
    t.integer "concurrency", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "last_heartbeat_at"
    t.string "model"
    t.string "name"
    t.string "public_id", null: false
    t.string "status", default: "offline", null: false
    t.jsonb "supported_roles", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_workers_on_public_id", unique: true
    t.index ["status"], name: "index_workers_on_status"
    t.index ["supported_roles"], name: "index_workers_on_supported_roles", using: :gin
  end

  create_table "workflows", force: :cascade do |t|
    t.datetime "compiled_at"
    t.datetime "created_at", null: false
    t.integer "max_iterations", default: 10, null: false
    t.integer "max_parallel", default: 4, null: false
    t.bigint "phase_id", null: false
    t.jsonb "shared_paths", default: [], null: false
    t.string "slug", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["phase_id", "slug"], name: "index_workflows_on_phase_id_and_slug", unique: true
    t.index ["phase_id"], name: "index_workflows_on_phase_id"
  end

  add_foreign_key "approvals", "phases"
  add_foreign_key "approvals", "phases", column: "target_phase_id"
  add_foreign_key "approvals", "users"
  add_foreign_key "archives", "pipelines"
  add_foreign_key "artifact_refs", "pipelines"
  add_foreign_key "manager_decisions", "phases"
  add_foreign_key "memberships", "projects"
  add_foreign_key "memberships", "users"
  add_foreign_key "phases", "pipelines"
  add_foreign_key "pipelines", "projects"
  add_foreign_key "project_assessments", "projects"
  add_foreign_key "project_assessments", "workers", column: "ran_by_worker_id"
  add_foreign_key "rework_events", "phases", column: "from_phase_id"
  add_foreign_key "rework_events", "phases", column: "target_phase_id"
  add_foreign_key "rework_events", "pipelines"
  add_foreign_key "step_edges", "steps", column: "from_step_id"
  add_foreign_key "step_edges", "steps", column: "to_step_id"
  add_foreign_key "step_edges", "workflows"
  add_foreign_key "step_runs", "steps"
  add_foreign_key "step_runs", "workers"
  add_foreign_key "step_templates", "projects"
  add_foreign_key "step_tokens", "step_runs"
  add_foreign_key "steps", "step_templates"
  add_foreign_key "steps", "workflows"
  add_foreign_key "workflows", "phases"
end
