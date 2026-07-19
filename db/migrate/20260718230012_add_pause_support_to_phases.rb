class AddPauseSupportToPhases < ActiveRecord::Migration[8.0]
  def change
    add_column :phases, :pause_requested, :boolean, default: false, null: false
    add_column :phases, :pause_requested_at, :datetime
    add_column :phases, :restart_in_progress, :boolean, default: false, null: false
    add_column :phases, :restart_feedback, :jsonb, default: [], null: false
  end
end
