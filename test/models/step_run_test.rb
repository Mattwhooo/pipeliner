require "test_helper"

class StepRunTest < ActiveSupport::TestCase
  test "duplicate (step, iteration, attempt) without shard is rejected by the DB" do
    existing = step_runs(:requirements_ready)
    dup = StepRun.new(
      step: existing.step, iteration: existing.iteration, attempt: existing.attempt,
      state: "ready", required_role: existing.required_role
    )
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "same (step, iteration, attempt) with distinct shard keys is allowed" do
    existing = step_runs(:requirements_ready)
    %w[shard-a shard-b].each do |key|
      StepRun.create!(
        step: existing.step, iteration: existing.iteration, attempt: existing.attempt,
        shard_key: key, state: "ready", required_role: existing.required_role
      )
    end
    assert_equal 2, StepRun.where.not(shard_key: nil).count
  end

  test "lease_expired scope finds only leased runs past expiry" do
    run = step_runs(:requirements_ready)
    run.update!(state: "running", worker: workers(:claude_local),
      lease_expires_at: 1.minute.ago)
    assert_includes StepRun.lease_expired, run

    run.update!(lease_expires_at: 1.minute.from_now)
    assert_not_includes StepRun.lease_expired, run
  end
end
