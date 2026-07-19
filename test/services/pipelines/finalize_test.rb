require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"

module Pipelines
  # Exercises the real finalization against local git repos: a bare "origin" with
  # a pipeline branch carrying both a `.pipeliner/` workspace and real repo files.
  # Mirrors the MergeStepBranch test harness (local bare repo + seeded branch).
  class FinalizeTest < ActiveSupport::TestCase
    PIPELINER_FILE = ".pipeliner/phases/04-review/main/critic/output/verdict.md".freeze
    CODE_FILE = "app/models/widget.rb".freeze

    setup do
      @tmp = Dir.mktmpdir("finalize-test")
      @origin = File.join(@tmp, "origin.git")
      seed_origin

      @project = Project.create!(name: "Repo Under Test", repo_url: @origin,
        default_branch: "main", project_type: "software", env_status: "ready")
      @pipeline = @project.pipelines.create!(title: "Feature", public_id: "pl_#{SecureRandom.hex(4)}",
        branch: "pipeliner/pl_feature", status: "running", current_phase: "review")
      @review = @pipeline.phases.create!(kind: "review", position: 4, status: "approved")
    end

    teardown do
      FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
      slug = @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
      FileUtils.rm_rf(Rails.root.join("tmp", "repos", slug))
      FileUtils.rm_f(Rails.root.join("tmp", "repos", "#{slug}.lock"))
      Dir.glob(Rails.root.join("storage", "archives", "#{@pipeline.public_id}-*.zip")).each { |z| File.delete(z) }
    end

    # --- happy path ---------------------------------------------------------

    test "archives the .pipeliner workspace, strips it from the branch, and completes the pipeline" do
      seed_pipeline_branch(files: { PIPELINER_FILE => "pass", CODE_FILE => "class Widget; end" })

      result = Finalize.call(pipeline: @pipeline)

      assert result.success?, "expected success, got #{result.error}"

      # Archive row indexes the local zip.
      archive = result.value
      assert_instance_of Archive, archive
      assert_equal "local", archive.s3_bucket
      assert archive.bytes.positive?, "archive records a non-zero byte count"
      assert_equal 1, @pipeline.archives.count

      # The zip exists on disk and actually contains the workspace.
      zip = Rails.root.join(archive.s3_key)
      assert File.exist?(zip), "archive zip written to #{archive.s3_key}"
      listing, ok = Open3.capture2e("unzip", "-l", zip.to_s)
      assert ok, "zip is readable"
      assert_match(/verdict\.md/, listing, "zip contains the .pipeliner content")

      # Origin's pipeline branch keeps real code but no longer carries .pipeliner.
      tree = origin_tree(@pipeline.branch)
      assert_includes tree, CODE_FILE, "real repo files survive finalization"
      assert_empty tree.select { |p| p.start_with?(".pipeliner/") }, ".pipeliner stripped from the branch"

      # Pipeline completed; pr_url untouched for a non-github (local path) remote.
      @pipeline.reload
      assert @pipeline.completed?
      assert_nil @pipeline.pr_url
    end

    test "completes gracefully when the branch has no .pipeliner tree (already stripped)" do
      seed_pipeline_branch(files: { CODE_FILE => "class Widget; end" })

      result = Finalize.call(pipeline: @pipeline)

      assert result.success?
      assert_nil @pipeline.archives.first, "no archive when there is nothing to zip"
      assert @pipeline.reload.completed?
      assert_includes origin_tree(@pipeline.branch), CODE_FILE
    end

    # --- guards -------------------------------------------------------------

    test "refuses to finalize when Review is not approved" do
      seed_pipeline_branch(files: { PIPELINER_FILE => "pass" })
      @review.update!(status: "consensus")

      result = Finalize.call(pipeline: @pipeline)

      assert result.failure?
      assert_equal :not_approved, result.error
      assert_equal 0, @pipeline.archives.count
      assert_includes origin_tree(@pipeline.branch), PIPELINER_FILE, "branch untouched when refused"
      assert_not @pipeline.reload.completed?
    end

    test "a second finalize is a safe no-op (already finalized)" do
      seed_pipeline_branch(files: { PIPELINER_FILE => "pass", CODE_FILE => "class Widget; end" })
      assert Finalize.call(pipeline: @pipeline).success?

      result = Finalize.call(pipeline: @pipeline)

      assert result.failure?
      assert_equal :already_finalized, result.error
      assert_equal 1, @pipeline.archives.count, "no duplicate archive on re-run"
    end

    test "fails cleanly when the pipeline branch is missing on origin" do
      # No seed_pipeline_branch — the branch never reaches origin.
      result = Finalize.call(pipeline: @pipeline)

      assert result.failure?
      assert_equal :branch_missing, result.error
      assert_equal 0, @pipeline.archives.count
    end

    # --- pr_url derivation (string logic; git remote stays the local bare path) ---

    test "derives a github compare url from an ssh remote" do
      finalize = build_finalize(repo_url: "git@github.com:acme/widgets.git", branch: "pipeliner/pl_x")
      assert_equal "https://github.com/acme/widgets/compare/main...pipeliner/pl_x",
        finalize.send(:compare_url)
    end

    test "derives a github compare url from an https remote (with and without .git)" do
      with_git = build_finalize(repo_url: "https://github.com/acme/widgets.git", branch: "feature")
      without = build_finalize(repo_url: "https://github.com/acme/widgets", branch: "feature")
      expected = "https://github.com/acme/widgets/compare/main...feature"
      assert_equal expected, with_git.send(:compare_url)
      assert_equal expected, without.send(:compare_url)
    end

    test "compare url is nil for a non-github remote" do
      finalize = build_finalize(repo_url: "/srv/git/widgets.git", branch: "feature")
      assert_nil finalize.send(:compare_url)
    end

    # --- opening the PR (adapter injected; no git or network) ---------------

    # A finalize whose git operations aren't exercised — used to unit-test the
    # PR-opening branch logic against a github URL without touching git.
    FakeGithub = Struct.new(:ready, :create_response, keyword_init: true) do
      attr_reader :create_args
      def ready? = ready
      def create_pr(**args)
        @create_args = args
        create_response
      end
    end

    test "opens a real PR via the adapter for a github project when gh is ready" do
      created = Github::Response.new(ok: true, url: "https://github.com/acme/widgets/pull/7", number: 7)
      finalize = build_finalize(repo_url: "https://github.com/acme/widgets", branch: "pipeliner/pl_x",
        github: FakeGithub.new(ready: true, create_response: created))

      url, number = finalize.send(:open_pull_request)

      assert_equal "https://github.com/acme/widgets/pull/7", url
      assert_equal 7, number
      args = finalize.instance_variable_get(:@github).create_args
      assert_equal "acme/widgets", args[:repo]
      assert_equal "main", args[:base]
      assert_equal "pipeliner/pl_x", args[:head]
      assert_match "🤖 Generated with Pipeliner", args[:body]
    end

    test "degrades to a nil url with a reason when the project has no github remote" do
      finalize = build_finalize(repo_url: "/srv/git/widgets.git", branch: "feature")
      url, number = finalize.send(:open_pull_request)
      assert_nil url
      assert_nil number
      assert_equal "this project has no GitHub remote", finalize.instance_variable_get(:@pr_note)
    end

    test "degrades to the compare url with a reason when gh is not ready" do
      finalize = build_finalize(repo_url: "https://github.com/acme/widgets", branch: "feature",
        github: FakeGithub.new(ready: false))
      url, number = finalize.send(:open_pull_request)
      assert_equal "https://github.com/acme/widgets/compare/main...feature", url
      assert_nil number
      assert_match(/GitHub CLI/, finalize.instance_variable_get(:@pr_note))
    end

    test "degrades to the compare url with a reason when opening the PR fails" do
      failed = Github::Response.new(ok: false, error: "a pull request already exists")
      finalize = build_finalize(repo_url: "https://github.com/acme/widgets", branch: "feature",
        github: FakeGithub.new(ready: true, create_response: failed))
      url, number = finalize.send(:open_pull_request)
      assert_equal "https://github.com/acme/widgets/compare/main...feature", url
      assert_nil number
      assert_match(/already exists/, finalize.instance_variable_get(:@pr_note))
    end

    test "records why the PR degraded to a compare link for a local-hub project" do
      seed_pipeline_branch(files: { CODE_FILE => "class Widget; end" })

      assert Finalize.call(pipeline: @pipeline).success?

      assert_equal "this project has no GitHub remote", @pipeline.reload.config["pr_note"]
    end

    test "pr body prefers the define summary and closes with the attribution line" do
      define = @pipeline.phases.create!(kind: "define", position: 1, status: "approved")
      workflow = define.workflows.create!(slug: "main", status: "running")
      step = workflow.steps.create!(slug: "define-review", step_type: "builder", role: "review", position: 1)
      step.step_runs.create!(state: "succeeded", iteration: 1, required_role: "review",
        result: { "artifacts" => { "define_summary" => "Ship the widget exporter." } })

      body = Finalize.new(pipeline: @pipeline).send(:pr_body)

      assert_match "Ship the widget exporter.", body
      assert body.end_with?("🤖 Generated with Pipeliner"), "closes with the attribution line"
    end

    # --- helpers ------------------------------------------------------------

    private

    def build_finalize(repo_url:, branch:, default_branch: "main", github: Pipelines::Github)
      project = Project.new(repo_url: repo_url, default_branch: default_branch)
      pipeline = Pipeline.new(branch: branch, project: project)
      Finalize.new(pipeline: pipeline, github: github)
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

    def seed_pipeline_branch(files:)
      seed = File.join(@tmp, "seed")
      git("checkout", "-b", @pipeline.branch, dir: seed)
      files.each do |path, contents|
        full = File.join(seed, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      git("add", "-A", dir: seed)
      git("commit", "-m", "pipeline work", dir: seed)
      git("push", "origin", @pipeline.branch, dir: seed)
    end

    def configure_identity(dir)
      git("config", "user.email", "worker@test.local", dir: dir)
      git("config", "user.name", "Test Worker", dir: dir)
    end

    def origin_tree(branch)
      git("ls-tree", "-r", "--name-only", branch, dir: @origin).split("\n").map(&:strip)
    end

    def git(*args, dir: nil)
      cmd = dir ? [ "git", "-C", dir, *args ] : [ "git", *args ]
      out, status = Open3.capture2e(*cmd)
      raise "#{cmd.join(" ")} failed: #{out}" unless status.success?
      out
    end
  end
end
