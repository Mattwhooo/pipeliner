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
  #      derive a GitHub compare URL, atomically, after the push commits.
  #   5. Broadcast the Review column.
  #
  # Local-first: the archive is written to storage/archives/ on local disk with
  # s3_bucket "local"; real S3 upload arrives with cloud hosting.
  #
  # Domain outcomes are Results; genuinely exceptional infra failures (clone,
  # fetch, zip, push) raise FinalizeError so the job surfaces and retries them.
  #
  # DEFERRED (out of scope here):
  #   * Phase-boundary commit squashing — the branch keeps its per-step merge
  #     commits; collapsing them into per-phase commits is future work.
  #   * Real S3 upload + retention policy (local-first stand-in for now).
  #   * Opening the PR via the GitHub API — we only derive the compare URL string.
  class Finalize
    GIT_TIMEOUT = 120 # seconds — generous for a clone/fetch/push, bounded for a hang.

    class FinalizeError < StandardError; end

    def self.call(pipeline:)
      new(pipeline:).call
    end

    def initialize(pipeline:)
      @pipeline = pipeline
      @project = pipeline.project
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
    def persist_finalization(zip_path)
      archive = nil
      ApplicationRecord.transaction do
        archive = create_archive_record(zip_path) if zip_path
        @pipeline.update!(status: "completed", pr_url: compare_url || @pipeline.pr_url)
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

    # --- PR link ------------------------------------------------------------

    # GitHub "compare" URL that pre-fills a PR from the default branch to the
    # pipeline branch. Only derived for github.com remotes (git@ or https forms);
    # nil otherwise so pr_url is left untouched.
    def compare_url
      slug = github_slug(@project.repo_url)
      return nil unless slug

      "https://github.com/#{slug}/compare/#{@project.default_branch}...#{@pipeline.branch}"
    end

    def github_slug(url)
      return nil if url.blank?

      case url
      when %r{\Agit@github\.com:(?<slug>[^/].*?)(?:\.git)?\z},
           %r{\Ahttps?://github\.com/(?<slug>[^/].*?)(?:\.git)?\z}
        Regexp.last_match(:slug)
      end
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
