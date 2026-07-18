class AddFeedbackToStepRuns < ActiveRecord::Migration[8.1]
  def change
    # Routed critic findings the Manager hands to a re-run (worker-executed
    # step). Mirrors the `feedback` array the worker writes into input.json.
    add_column :step_runs, :feedback, :jsonb, null: false, default: []
  end
end
