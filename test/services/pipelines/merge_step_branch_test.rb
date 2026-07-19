require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"

module Pipelines
  # Exercises the real merge against local git repos: a bare "origin", a seeded
  # pipeline branch, and a simulated worker that clones, branches, commits under
  # the step's .pipeliner subtree, and pushes its step branch.
  class MergeStepBranchTest < ActiveSupport::TestCase
    setup do
      @tmp = Dir.mktmpdir("merge-test")
      @origin = File.join(@tmp, "origin.git")
      seed_origin

      @project = Project.create!(name: "Repo Under Test", repo_url: @origin,
        default_branch: "main", project_type: "software", env_status: "ready")
      @pipeline = @project.pipelines.create!(title: "Feature", public_id: "pl_#{SecureRandom.hex(4)}",
        branch: "pipeliner/pl_feature", status: "running", current_phase: "define")
      @phase = @pipeline.phases.create!(kind: "define", position: 1, status: "running")
      @workflow = @phase.workflows.create!(slug: "main", status: "running")
      seed_pipeline_branch
    end

    teardown do
      FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
      slug = @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
      FileUtils.rm_rf(Rails.root.join("tmp", "repos", slug))
      FileUtils.rm_f(Rails.root.join("tmp", "repos", "#{slug}.lock"))
    end

    # --- happy path ---------------------------------------------------------

    test "merges the step branch, sets merged_at, deletes the branch, indexes outputs" do
      step = build_step(outputs: [
        { "artifact" => "discovery_notes", "kind" => "artifact", "path" => "output/notes.md" }
      ])
      artifact_path = "#{pipeliner_prefix(step)}output/notes.md"
      run = push_step_branch(step, files: { artifact_path => "notes" })

      result = MergeStepBranch.call(step_run: run)

      assert result.success?, "expected success, got #{result.error}"
      run.reload
      assert run.merged?, "merged_at set"
      assert_nil run.merge_error
      assert_equal "succeeded", run.state

      assert_includes origin_tree(@pipeline.branch), artifact_path, "artifact merged onto pipeline branch"
      assert_not origin_has_branch?(run.step_branch), "step branch deleted from origin"

      ref = @pipeline.artifact_refs.find_by(name: "discovery_notes")
      assert ref, "ArtifactRef indexed"
      assert_equal "artifact", ref.kind
      assert_equal "output/notes.md", ref.path
      assert_equal origin_head(@pipeline.branch), ref.commit_sha, "commit_sha = merge result"
    end

    test "later steps' worktrees contain earlier merged artifacts on the pipeline branch" do
      first = build_step(slug: "explore", outputs: [ { "artifact" => "a", "kind" => "artifact" } ])
      first_path = "#{pipeliner_prefix(first)}output/notes.md"
      first_run = push_step_branch(first, files: { first_path => "explore output" })
      assert MergeStepBranch.call(step_run: first_run).success?

      # A worker branching off the pipeline branch now sees the first step's file.
      work = File.join(@tmp, "later-worktree")
      git("clone", "--branch", @pipeline.branch, @origin, work)
      assert File.exist?(File.join(work, first_path)), "earlier artifact present in a fresh worktree"
    end

    # --- scope enforcement --------------------------------------------------

    test "a change outside the step's scope fails the run and records merge_error" do
      step = build_step(outputs: [ { "artifact" => "notes", "kind" => "artifact" } ])
      run = push_step_branch(step, files: { "README.md" => "sneaky repo edit" })

      result = MergeStepBranch.call(step_run: run)

      assert result.failure?
      assert_equal :scope_violation, result.error
      run.reload
      assert_equal "failed", run.state
      assert_match(/scope violation/, run.merge_error)
      assert_match(/README\.md/, run.merge_error)
      assert_nil run.merged_at
      assert origin_has_branch?(run.step_branch), "offending branch is left unmerged, not deleted"
    end

    test "a repo-output step may change repo files within its declared scope globs" do
      step = build_step(
        outputs: [ { "artifact" => "build_notes", "kind" => "repo" } ],
        scope: { "paths" => [ "app/**" ] }
      )
      run = push_step_branch(step, files: { "app/models/thing.rb" => "class Thing; end" })

      result = MergeStepBranch.call(step_run: run)

      assert result.success?, "in-scope repo change merges (got #{result.error})"
      assert_includes origin_tree(@pipeline.branch), "app/models/thing.rb"
    end

    test "a repo-output step changing files outside its scope globs is rejected" do
      step = build_step(
        outputs: [ { "artifact" => "build_notes", "kind" => "repo" } ],
        scope: { "paths" => [ "app/**" ] }
      )
      run = push_step_branch(step, files: { "config/secrets.yml" => "leak" })

      result = MergeStepBranch.call(step_run: run)

      assert_equal :scope_violation, result.error
      assert_equal "failed", run.reload.state
    end

    # --- edge cases ---------------------------------------------------------

    test "a run with no commit_sha is a no-op success with no git activity" do
      step = build_step(outputs: [])
      run = step.step_runs.create!(state: "succeeded", iteration: 1,
        required_role: step.role, commit_sha: nil, step_branch: "step/none")

      result = MergeStepBranch.call(step_run: run)

      assert result.success?
      assert run.reload.merged?
      slug = @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
      assert_not Dir.exist?(Rails.root.join("tmp", "repos", slug)), "no clone created for a no-op merge"
    end

    test "a duplicate merge for the same (step, iteration, shard) is skipped" do
      step = build_step(outputs: [])
      already = step.step_runs.create!(state: "succeeded", iteration: 1,
        required_role: step.role, commit_sha: "abc", merged_at: Time.current)
      dup = step.step_runs.create!(state: "succeeded", iteration: 1, attempt: 2,
        required_role: step.role, commit_sha: "def", step_branch: "step/dup")

      result = MergeStepBranch.call(step_run: dup)

      assert result.failure?
      assert_equal :duplicate, result.error
      assert_nil dup.reload.merged_at
      assert already.reload.merged?
    end

    test "an already-merged run is not merged again" do
      step = build_step(outputs: [])
      run = step.step_runs.create!(state: "succeeded", iteration: 1,
        required_role: step.role, commit_sha: "abc", merged_at: Time.current, step_branch: "step/x")

      result = MergeStepBranch.call(step_run: run)

      assert_equal :already_merged, result.error
    end

    # --- helpers ------------------------------------------------------------

    private

    def build_step(slug: "requirements", outputs:, scope: nil)
      @workflow.steps.create!(slug: slug, step_type: "builder", role: "requirements",
        position: @workflow.steps.count + 1, outputs: outputs, scope: scope)
    end

    def pipeliner_prefix(step)
      ".pipeliner/phases/01-define/#{@workflow.slug}/#{step.slug}/"
    end

    # Simulate a worker: clone origin, cut a step branch off the pipeline branch,
    # write files, commit, push the step branch. Returns a succeeded step_run
    # carrying that branch + commit sha, as StepRuns::Complete would have left it.
    def push_step_branch(step, files:)
      branch = "step/01-define/#{@workflow.slug}/#{step.slug}/#{SecureRandom.hex(4)}"
      work = File.join(@tmp, "worker-#{SecureRandom.hex(4)}")
      git("clone", "--branch", @pipeline.branch, @origin, work)
      configure_identity(work)
      git("checkout", "-b", branch, dir: work)
      files.each do |path, contents|
        full = File.join(work, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      git("add", "-A", dir: work)
      git("commit", "-m", "worker output", dir: work)
      sha = git("rev-parse", "HEAD", dir: work).strip
      git("push", "origin", branch, dir: work)

      step.step_runs.create!(state: "succeeded", iteration: 1, required_role: step.role,
        commit_sha: sha, step_branch: branch, finished_at: Time.current)
    end

    def seed_origin
      git("init", "--bare", "-b", "main", @origin)
      seed = File.join(@tmp, "seed")
      git("clone", @origin, seed)
      configure_identity(seed)
      File.write(File.join(seed, "README.md"), "# Repo\n")
      git("add", "-A", dir: seed)
      git("commit", "-m", "initial", dir: seed)
      git("push", "origin", "main", dir: seed)
    end

    def seed_pipeline_branch
      seed = File.join(@tmp, "seed")
      git("checkout", "-b", @pipeline.branch, dir: seed)
      git("push", "origin", @pipeline.branch, dir: seed)
    end

    def configure_identity(dir)
      git("config", "user.email", "worker@test.local", dir: dir)
      git("config", "user.name", "Test Worker", dir: dir)
    end

    def origin_tree(branch)
      git("ls-tree", "-r", "--name-only", branch, dir: @origin).split("\n").map(&:strip)
    end

    def origin_head(branch)
      git("rev-parse", branch, dir: @origin).strip
    end

    def origin_has_branch?(branch)
      out, status = Open3.capture2e("git", "-C", @origin, "show-ref", "--verify", "refs/heads/#{branch}")
      status.success? && out.present?
    end

    def git(*args, dir: nil)
      cmd = dir ? [ "git", "-C", dir, *args ] : [ "git", *args ]
      out, status = Open3.capture2e(*cmd)
      raise "#{cmd.join(" ")} failed: #{out}" unless status.success?
      out
    end
  end
end
