require "test_helper"

module Phases
  class AdvanceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @project = Project.create!(name: "Repo", repo_url: "git@github.com:acme/repo-#{SecureRandom.hex(4)}.git",
        default_branch: "main", project_type: "software", env_status: "ready")
      @pipeline = @project.pipelines.create!(title: "Feature", public_id: "pl_#{SecureRandom.hex(4)}",
        branch: "pipeliner/pl_feature", status: "running", current_phase: "plan")
      @plan = @pipeline.phases.create!(kind: "plan", position: 2, status: "approved")
      @build = @pipeline.phases.create!(kind: "build", position: 3, status: "pending")
      @review = @pipeline.phases.create!(kind: "review", position: 4, status: "approved")
    end

    # --- non-review advance -------------------------------------------------

    test "advances to the next phase, updating both writes, and broadcasts after commit" do
      seen = capture_broadcasts do
        result = Advance.call(phase: @plan)
        assert result.success?
        assert_equal @build, result.value
      end

      # Both state writes landed.
      assert @build.reload.running?
      @pipeline.reload
      assert_equal "build", @pipeline.current_phase
      assert @pipeline.running?

      # Broadcasts fired for both columns, and saw the committed state (the next
      # phase was already "running" when its column broadcast — proof the writes
      # committed before any broadcast).
      assert_includes seen, [ "plan", "approved" ]
      assert_includes seen, [ "build", "running" ]
    end

    test "the two state writes are atomic — a failure rolls both back" do
      pipeline = @plan.pipeline
      def pipeline.update!(*)
        raise "boom"
      end

      assert_raises(RuntimeError) { Advance.call(phase: @plan) }

      assert @build.reload.pending?, "next phase write rolled back with the pipeline write"
      assert_equal "plan", @pipeline.reload.current_phase, "pipeline unchanged"
    end

    # --- review advance -----------------------------------------------------

    test "approving Review enqueues finalization and does not mark completed inline" do
      assert_enqueued_with(job: Pipelines::FinalizeJob, args: [ @pipeline ]) do
        result = Advance.call(phase: @review)
        assert result.success?
        assert_equal @pipeline, result.value
      end

      assert_not @pipeline.reload.completed?, "completion is Finalize's job, not Advance's"
    end

    private

    # Swap Phases::BroadcastColumn.call for a recorder that captures each phase's
    # (kind, status) at the moment it is broadcast. No mocking library in this
    # repo, so we replace + restore the singleton method directly.
    def capture_broadcasts
      seen = []
      original = BroadcastColumn.method(:call)
      BroadcastColumn.define_singleton_method(:call) { |phase| seen << [ phase.kind, phase.status ] }
      yield
      seen
    ensure
      BroadcastColumn.singleton_class.send(:remove_method, :call)
      BroadcastColumn.define_singleton_method(:call, original)
    end
  end
end
