require "open3"
require "timeout"
require "fileutils"

module Pipelines
  # Finalizes an approved pipeline at the end of Review (docs/artifact-schema.md
  # "Finalization"): the `.pipeliner/` workspace is working scaffolding, not
  # shipped code, so before the branch becomes a real PR we archive that tree and
  # strip it from the branch, leaving only genuine repo changes.
  #
  # Flow (all git in a control-plane-private clone under tmp/repos/<slug>, the
  # same clone + OS-flock convention as Pipelines::MergeStepBranch):
  #   1. Guards: Review must be approved (:not_approved); an existing Archive means
  #      already finalized (:already_finalized) — this is what makes the job
  #      retry-safe. The pipeline branch must exist on origin (:branch_missing).
  #   2. Refresh the clone, check out the pipeline branch.
  #   3. If the branch carries a `.pipeliner/` tree: zip it to local disk, then
  #      `git rm -r` it, commit the strip, and push. (Already-stripped branches —
  #      e.g. a retry after a mid-flight failure — skip this gracefully.)
  #   4. Persist: create the Archive index row + mark the pipeline completed +
  #      open the real GitHub PR (or fall back to a compare URL), atomically,
  #      after the push commits.
  #   5. Broadcast the Review column.
  #
  # Opening the PR: once the clean branch is on origin we open a real PR with the
  # `gh` CLI (Pipelines::Github). It degrades gracefully to the compare-link
  # behavior — recording *why* in `pipeline.config["pr_note"]` — when the project
  # is a local hub (no GitHub remote) or gh is missing/unauthenticated. The PR
  # number is stored so Pipelines::MergePr can later merge it.
  #
  # Local-first: the archive is written to storage/archives/ on local disk with
  # s3_bucket "local"; real S3 upload arrives with cloud hosting.
  #
  # Domain outcomes are Results; genuinely exceptional infra failures (clone,
  # fetch, zip, push) raise FinalizeError so the job surfaces and retries them.
  # A gh failure is NOT exceptional — it degrades to the compare link.
  #
  # DEFERRED (out of scope here):
  #   * Phase-boundary commit squashing — the branch keeps its per-step merge
  #     commits; collapsing them into per-phase commits is future work.
  #   * Real S3 upload + retention policy (local-first stand-in for now).
  class Finalize
    GIT_TIMEOUT = 120 # seconds — generous for a clone/fetch/push, bounded for a hang.

    class FinalizeError < StandardError; end

    def self.call(pipeline:, github: Pipelines::Github)
      new(pipeline:, github:).call
    end

    def initialize(pipeline:, github: Pipelines::Github)
      @pipeline = pipeline
      @project = pipeline.project
      @github = github
    end

    def call
      return Result.failure(:not_approved, record: @pipeline) unless review_approved?
      return Result.failure(:already_finalized, record: @pipeline) if @pipeline.archives.exists?

      # One project clone is shared across that project's pipelines; the OS lock
      # keeps a finalize off the same working tree as a concurrent merge/finalize.
      with_repo_lock { finalize! }
    end

    private

    # --- orchestration ------------------------------------------------------

    def finalize!
      prepare_repo
      return Result.failure(:branch_missing, record: @pipeline) unless remote_has_branch?(@pipeline.branch)

      checkout_pipeline_branch
      zip_path = strip_workspace # nil when `.pipeliner/` is already gone.

      archive = persist_finalization(zip_path)

      # Broadcast only after the state writes commit (never inside the transaction).
      Phases::BroadcastColumn.call(review_phase)
      Dashboard::Broadcast.call(pipeline: @pipeline, activity: true)
      Result.success(archive || @pipeline)
    end

    # Zip the `.pipeliner/` tree, then remove it, commit the strip, and push.
    # Returns the zip path (for the Archive row), or nil when there is nothing to
    # strip — a fresh clone whose branch was already finalized by an earlier
    # attempt that failed before persisting.
    def strip_workspace
      return nil unless File.directory?(repo_dir.join(".pipeliner"))

      zip_path = build_archive_zip
      git!("rm", "-r", "--quiet", ".pipeliner")
      git!("commit", "-m", commit_message)
      push_pipeline_branch
      zip_path
    end

    # Archive index row + pipeline completion in one transaction, after the push.
    # The PR is opened (or the fallback derived) BEFORE the transaction so its
    # network call never holds a DB transaction open.
    def persist_finalization(zip_path)
      pr_url, pr_number = open_pull_request
      archive = nil
      ApplicationRecord.transaction do
        archive = create_archive_record(zip_path) if zip_path
        @pipeline.update!(status: "completed", pr_url: pr_url || @pipeline.pr_url,
          pr_number: pr_number, config: pr_config)
      end
      archive
    end

    def commit_message
      "Finalize #{@pipeline.public_id}: archive and strip the .pipeliner workspace"
    end

    # --- guards -------------------------------------------------------------

    def review_approved?
      review_phase&.approved?
    end

    def review_phase
      @review_phase ||= @pipeline.phases.find_by(kind: "review")
    end

    # --- archiving ----------------------------------------------------------

    # `zip -r` over the checked-out working tree, writing to a gitignored local
    # path (storage/ is ignored). Timestamped so a retry never clobbers a prior
    # zip. Runs from inside the clone so archived paths are workspace-relative.
    def build_archive_zip
      dir = Rails.root.join("storage", "archives")
      FileUtils.mkdir_p(dir)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      zip_path = dir.join("#{@pipeline.public_id}-#{timestamp}.zip")

      out, ok = run([ "zip", "-r", "-q", zip_path.to_s, ".pipeliner" ], chdir: repo_dir.to_s)
      raise FinalizeError, "zip failed: #{out}" unless ok
      zip_path
    end

    def create_archive_record(zip_path)
      Archive.create!(
        pipeline: @pipeline,
        s3_bucket: "local",
        s3_key: zip_path.relative_path_from(Rails.root).to_s,
        bytes: File.size(zip_path)
      )
    end

    # --- PR opening ---------------------------------------------------------

    # Opens the real GitHub PR and returns [pr_url, pr_number]. Degrades to
    # [compare_url, nil] (recording the reason in @pr_note) when there is no
    # GitHub remote, gh isn't ready, or the create call fails. Idempotent: a
    # pipeline that already carries a PR number keeps it (a retry never opens a
    # duplicate PR).
    def open_pull_request
      return [ @pipeline.pr_url, @pipeline.pr_number ] if @pipeline.pr_number.present?
      return degrade("this project has no GitHub remote") unless @project.github?
      return degrade("the GitHub CLI is unavailable or not authenticated") unless @github.ready?

      response = @github.create_pr(repo: @project.github_slug, base: @project.default_branch,
        head: @pipeline.branch, title: @pipeline.title, body: pr_body)
      return degrade("opening the PR failed: #{response.error}") unless response.ok?

      @pr_note = nil
      [ response.url, response.number ]
    end

    def degrade(reason)
      @pr_note = reason
      [ compare_url, nil ]
    end

    # Merges the pr_note into config without clobbering the pipeline's other
    # config; a successful open clears any stale note.
    def pr_config
      base = @pipeline.config.except("pr_note")
      @pr_note.present? ? base.merge("pr_note" => @pr_note) : base
    end

    # PR body: the Define summary if we have one, else the requirements, else the
    # original ask — always closing with the Pipeliner attribution line.
    def pr_body
      body = define_artifact("define_summary").presence ||
        define_artifact("business_requirements").presence ||
        @pipeline.initial_prompt.to_s
      [ body.to_s.strip, "🤖 Generated with Pipeliner" ].reject(&:blank?).join("\n\n")
    end

    # Reads a Define artifact off its latest succeeded run's mirrored result,
    # the same way DefineHelper surfaces it in the UI (no git access needed).
    def define_artifact(name)
      define = @pipeline.phases.find_by(kind: "define")
      return nil unless define

      run = define.workflows.flat_map(&:steps).flat_map(&:step_runs)
        .select { |r| r.succeeded? && artifact_from(r, name).present? }
        .max_by { |r| [ r.iteration, r.attempt, r.id ] }
      run && artifact_from(run, name)
    end

    def artifact_from(run, name)
      return nil unless run.result.is_a?(Hash)

      artifacts = run.result["artifacts"]
      artifacts.is_a?(Hash) ? artifacts[name].presence : nil
    end

    # GitHub "compare" URL that pre-fills a PR from the default branch to the
    # pipeline branch — the fallback when we can't open a real PR. Only derived
    # for github.com remotes; nil otherwise so pr_url is left untouched.
    def compare_url
      slug = @project.github_slug
      return nil unless slug

      "https://github.com/#{slug}/compare/#{@project.default_branch}...#{@pipeline.branch}"
    end

    # --- git working tree (replicates MergeStepBranch conventions) -----------

    def prepare_repo
      FileUtils.mkdir_p(repos_root)
      if Dir.exist?(repo_dir.join(".git"))
        git!("fetch", "origin", "--prune")
      else
        out, ok = run([ "git", "clone", @project.repo_url, repo_dir.to_s ])
        raise FinalizeError, "git clone failed: #{out}" unless ok
      end
      # Local identity so the finalization commit never depends on ambient config.
      git!("config", "user.email", "control-plane@pipeliner.local")
      git!("config", "user.name", "Pipeliner Control Plane")
    end

    def checkout_pipeline_branch
      git!("checkout", "-B", @pipeline.branch, "origin/#{@pipeline.branch}")
    end

    def push_pipeline_branch
      git!("push", "origin", @pipeline.branch)
    end

    def remote_has_branch?(branch)
      out, ok = git("ls-remote", "--heads", "origin", branch)
      ok && out.strip.present?
    end

    # --- shelling out (same shape as MergeStepBranch) -----------------------

    def with_repo_lock
      FileUtils.mkdir_p(repos_root)
      lock = File.open(repos_root.join("#{url_slug}.lock"), File::RDWR | File::CREAT, 0o644)
      lock.flock(File::LOCK_EX)
      yield
    ensure
      if lock
        lock.flock(File::LOCK_UN)
        lock.close
      end
    end

    def git!(*args, dir: repo_dir)
      out, ok = git(*args, dir: dir)
      raise FinalizeError, "git #{args.first} failed: #{out}" unless ok
      out
    end

    def git(*args, dir: repo_dir)
      run([ "git", "-C", dir.to_s, *args ])
    end

    def run(command, chdir: nil)
      out = nil
      status = nil
      opts = chdir ? { chdir: chdir } : {}
      Timeout.timeout(GIT_TIMEOUT) { out, status = Open3.capture2e(*command, **opts) }
      [ out, status.success? ]
    rescue Timeout::Error
      [ "command timed out: #{command.join(" ")}", false ]
    end

    def repos_root
      Rails.root.join("tmp", "repos")
    end

    def repo_dir
      repos_root.join(url_slug)
    end

    # Deterministic, filesystem-safe clone dir per project repo — the same scheme
    # MergeStepBranch uses, so both services share one clone per project.
    def url_slug
      @url_slug ||= @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
    end
  end
end
