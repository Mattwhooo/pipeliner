class AddMergeTrackingToStepRuns < ActiveRecord::Migration[8.1]
  # Tracks the control-plane merge of a step branch into the pipeline branch.
  # A succeeded run is only a *predecessor* (unblocks dependents / counts toward
  # consensus) once `merged_at` is set — so the backfill below is mandatory:
  # without it, every in-flight pipeline's already-succeeded runs would look
  # unmerged under the new dispatch rule and stall forever.
  def up
    add_column :step_runs, :merged_at, :datetime
    add_column :step_runs, :merge_error, :text

    # Treat pre-existing successes as already merged (their branches were merged
    # under the old flow, or there was nothing to merge). finished_at is the
    # truthful merge time when present; now is a safe fallback.
    execute(<<~SQL.squish)
      UPDATE step_runs
      SET merged_at = COALESCE(finished_at, NOW())
      WHERE state = 'succeeded' AND merged_at IS NULL
    SQL
  end

  def down
    remove_column :step_runs, :merge_error
    remove_column :step_runs, :merged_at
  end
end
