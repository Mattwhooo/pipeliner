require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"

module Pipelines
  # Exercises the real merge-from-base against local git repos: a bare "origin"
  # with a default branch and a pipeline branch cut from it. Mirrors the
  # MergeStepBranch/Finalize harness (local bare repo + seeded branch).
  class UpdateFromBaseTest < ActiveSupport::TestCase
    setup do
      @tmp = Dir.mktmpdir("update-base-test")
      @origin = File.join(@tmp, "origin.git")
      seed_origin

      @project = Project.create!(name: "Repo Under Test", repo_url: @origin,
        default_branch: "main", project_type: "software", env_status: "ready")
      @pipeline = @project.pipelines.create!(title: "Feature", public_id: "pl_#{SecureRandom.hex(4)}",
        branch: "pipeliner/pl_feature", status: "running", current_phase: "review")
    end

    teardown do
      FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
      slug = @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
      FileUtils.rm_rf(Rails.root.join("tmp", "repos", slug))
      FileUtils.rm_f(Rails.root.join("tmp", "repos", "#{slug}.lock"))
    end

    test "merges new base commits into the pipeline branch and pushes" do
      seed_pipeline_branch(files: { "feature.txt" => "feature work" })
      commit_on_base(files: { "base.txt" => "landed on main after the branch was cut" })

      result = UpdateFromBase.call(pipeline: @pipeline)

      assert result.success?, "expected success, got #{result.error}"
      tree = origin_tree(@pipeline.branch)
      assert_includes tree, "base.txt", "base changes merged onto the pipeline branch"
      assert_includes tree, "feature.txt", "the branch's own work is preserved"
    end

    test "a conflicting base change aborts cleanly, pushes nothing, and surfaces a message" do
      seed_pipeline_branch(files: { "README.md" => "pipeline version\n" })
      before = origin_head(@pipeline.branch)
      commit_on_base(files: { "README.md" => "base version\n" })

      result = UpdateFromBase.call(pipeline: @pipeline)

      assert result.failure?
      assert_equal :merge_conflict, result.error
      assert_match(/conflicts/, @pipeline.reload.config["update_error"])
      assert_equal before, origin_head(@pipeline.branch), "nothing was pushed on conflict"
    end

    test "is a clean success when the branch is already up to date with base" do
      seed_pipeline_branch(files: { "feature.txt" => "feature work" })
      before = origin_head(@pipeline.branch)

      result = UpdateFromBase.call(pipeline: @pipeline)

      assert result.success?
      assert_nil @pipeline.reload.config["update_error"]
      assert_equal before, origin_head(@pipeline.branch), "no merge commit when already current"
    end

    test "fails cleanly when the pipeline branch is missing on origin" do
      # No seed_pipeline_branch — the branch never reaches origin.
      result = UpdateFromBase.call(pipeline: @pipeline)

      assert result.failure?
      assert_equal :branch_missing, result.error
    end

    # --- helpers ------------------------------------------------------------

    private

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

    def seed_pipeline_branch(files:)
      seed = File.join(@tmp, "seed")
      git("checkout", "-b", @pipeline.branch, dir: seed)
      write_and_push(seed, @pipeline.branch, files, "pipeline work")
    end

    def commit_on_base(files:)
      work = File.join(@tmp, "base-#{SecureRandom.hex(4)}")
      git("clone", "--branch", "main", @origin, work)
      configure_identity(work)
      write_and_push(work, "main", files, "later work on main")
    end

    def write_and_push(dir, branch, files, message)
      files.each do |path, contents|
        full = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      git("add", "-A", dir: dir)
      git("commit", "-m", message, dir: dir)
      git("push", "origin", branch, dir: dir)
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

    def git(*args, dir: nil)
      cmd = dir ? [ "git", "-C", dir, *args ] : [ "git", *args ]
      out, status = Open3.capture2e(*cmd)
      raise "#{cmd.join(" ")} failed: #{out}" unless status.success?
      out
    end
  end
end
