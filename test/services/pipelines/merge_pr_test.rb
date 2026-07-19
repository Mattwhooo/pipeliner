require "test_helper"

module Pipelines
  # The gh adapter is a fake throughout — MergePr never touches the network.
  class MergePrTest < ActiveSupport::TestCase
    # Records the merge_pr call and returns a canned Response.
    FakeGithub = Struct.new(:ready, :response, keyword_init: true) do
      attr_reader :merge_args
      def ready? = ready
      def merge_pr(**args)
        @merge_args = args
        response
      end
    end

    setup do
      @project = Project.create!(name: "Repo", repo_url: "https://github.com/acme/widgets",
        default_branch: "main", project_type: "software", env_status: "ready")
      @pipeline = @project.pipelines.create!(title: "Feature", public_id: "pl_#{SecureRandom.hex(4)}",
        branch: "pipeliner/pl_feature", status: "completed", current_phase: "review",
        pr_url: "https://github.com/acme/widgets/pull/7", pr_number: 7)
    end

    test "merges via the adapter (squash) and marks the pipeline merged" do
      github = FakeGithub.new(ready: true, response: Github::Response.new(ok: true))

      result = MergePr.call(pipeline: @pipeline, github: github)

      assert result.success?
      assert @pipeline.reload.merged?
      assert_equal({ "repo" => "acme/widgets", "number" => 7, "method" => "squash" },
        github.merge_args.transform_keys(&:to_s))
    end

    test "clears any prior merge error on a successful merge" do
      @pipeline.update!(config: { "merge_error" => "old failure" })
      github = FakeGithub.new(ready: true, response: Github::Response.new(ok: true))

      assert MergePr.call(pipeline: @pipeline, github: github).success?
      assert_nil @pipeline.reload.config["merge_error"]
    end

    test "surfaces a non-mergeable PR as a failure with the gh message, without crashing" do
      github = FakeGithub.new(ready: true,
        response: Github::Response.new(ok: false, error: "not mergeable: conflicts"))

      result = MergePr.call(pipeline: @pipeline, github: github)

      assert result.failure?
      assert_equal :merge_failed, result.error
      assert_not @pipeline.reload.merged?
      assert_match(/conflicts/, @pipeline.config["merge_error"])
    end

    test "refuses to merge an already-merged pipeline" do
      @pipeline.update!(status: "merged")
      result = MergePr.call(pipeline: @pipeline, github: FakeGithub.new(ready: true))
      assert_equal :already_merged, result.error
    end

    test "fails when there is no PR number (compare-link fallback pipeline)" do
      @pipeline.update!(pr_number: nil)
      result = MergePr.call(pipeline: @pipeline, github: FakeGithub.new(ready: true))
      assert_equal :no_pr, result.error
    end

    test "fails when gh is unavailable or unauthenticated" do
      result = MergePr.call(pipeline: @pipeline, github: FakeGithub.new(ready: false))
      assert_equal :gh_unavailable, result.error
      assert_not @pipeline.reload.merged?
    end

    test "fails gracefully for a local-hub project with no github remote" do
      local = Project.create!(name: "Hub", repo_url: "/srv/git/hub.git",
        default_branch: "main", project_type: "software", env_status: "ready")
      pipeline = local.pipelines.create!(title: "Local", public_id: "pl_#{SecureRandom.hex(4)}",
        branch: "pipeliner/pl_local", status: "completed", current_phase: "review", pr_number: 3)

      result = MergePr.call(pipeline: pipeline, github: FakeGithub.new(ready: true))

      assert_equal :no_remote, result.error
    end
  end
end
