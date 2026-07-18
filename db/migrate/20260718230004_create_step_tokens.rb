class CreateStepTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :step_tokens do |t|
      t.references :step_run, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :allowed_ref
      t.jsonb :scopes, null: false, default: []
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :step_tokens, :token_digest, unique: true
  end
end
