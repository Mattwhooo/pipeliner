class CreateWorkers < ActiveRecord::Migration[8.1]
  def change
    create_table :workers do |t|
      t.string :public_id, null: false
      t.string :name
      t.string :status, null: false, default: "offline"
      t.string :backend
      t.string :model
      t.jsonb :supported_roles, null: false, default: []
      t.integer :concurrency, null: false, default: 1
      t.datetime :last_heartbeat_at
      t.string :auth_token_digest, null: false

      t.timestamps
    end
    add_index :workers, :public_id, unique: true
    add_index :workers, :status
    add_index :workers, :supported_roles, using: :gin
  end
end
