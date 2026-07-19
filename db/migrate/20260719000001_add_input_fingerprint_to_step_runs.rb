class AddInputFingerprintToStepRuns < ActiveRecord::Migration[8.1]
  # A content-identity of the declared inputs + routed feedback a run consumed at
  # dispatch (Phases::InputFingerprint). The Manager reuses a prior succeeded run
  # instead of re-dispatching a worker when a step's inputs are unchanged
  # (docs/execution-model.md — "Skip re-running unchanged steps"). Nullable: runs
  # predating this column (and human/awaiting_input runs) simply have none, and a
  # blank fingerprint never matches, so those never trigger a reuse.
  def change
    add_column :step_runs, :input_fingerprint, :string
  end
end
