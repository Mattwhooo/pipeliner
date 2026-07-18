class CreateProjectsAndMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :repo_url, null: false
      t.string :default_branch, null: false, default: "main"
      t.string :project_type, null: false, default: "software"
      t.string :github_app_installation_id
      t.string :env_status, null: false, default: "pending"
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end
    add_index :projects, :repo_url, unique: true

    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :role, null: false, default: "member"

      t.timestamps
    end
    add_index :memberships, [ :user_id, :project_id ], unique: true
  end
end
