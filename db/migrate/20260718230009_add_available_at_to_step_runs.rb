class AddAvailableAtToStepRuns < ActiveRecord::Migration[8.1]
  def change
    # Backoff gate for transient failures (session/rate limits, API outages):
    # a ready run is claimable only once available_at passes (null = now).
    add_column :step_runs, :available_at, :datetime
    add_index :step_runs, :available_at
  end
end
