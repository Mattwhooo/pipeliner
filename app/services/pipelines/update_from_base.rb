require "open3"
require "timeout"
require "fileutils"

module Pipelines
  # The long-missing "update from base" operation (docs/architecture.md M9,
  # docs/scenario-pressure-test.md): merges the project's default branch INTO the
  # pipeline branch and pushes, so a long-running pipeline branch can pick up
  # changes that landed on the base since it was cut.
  #
  # It is a MERGE, not a literal rebase: the pipeline branch already has an open
  # PR whose history is shared, so we layer a forward merge commit (never rewrite
  # history) — same forward-only rule as inter-phase rework. The button is named
  # "Update from main" to make that clear.
  #
  # Reuses MergeStepBranch/Finalize's git infrastructure: the same per-project
  # clone under tmp/repos/<slug> and the OS flock, so an update never shares a
  # working tree with a concurrent merge or finalize on the same project.
  #
  # Flow (all git in the control-plane-private clone):
  #   1. Refresh the clone, guard that the pipeline branch is on origin.
  #   2. Check out the pipeline branch (reset to origin's), fetch the base.
  #   3. Merge origin/<default_branch> in. A conflict aborts cleanly and surfaces
  #      a message (`config["update_error"]`) — nothing is pushed.
  #   4. If the merge changed the branch, push; if it was already up to date,
  #      succeed without pushing.
  #
  # Domain outcomes (branch missing, conflict) are Results; genuinely exceptional
  # git/infra failures (clone/fetch/push) raise UpdateError so the caller surfaces
  # and retries them.
  class UpdateFromBase
    GIT_TIMEOUT = 120 # seconds — generous for a fetch/clone, bounded for a hang.

    class UpdateError < StandardError; end

    def self.call(pipeline:)
      new(pipeline:).call
    end

    def initialize(pipeline:)
      @pipeline = pipeline
      @project = pipeline.project
    end

    def call
      with_repo_lock { update! }
    end

    private

    # --- orchestration ------------------------------------------------------

    def update!
      prepare_repo
      unless remote_has_branch?(@pipeline.branch)
        return failure(:branch_missing, "The pipeline branch isn't on the remote yet.")
      end

      checkout_pipeline_branch
      git!("fetch", "origin", @project.default_branch)

      before = rev_parse("HEAD")
      unless run_merge
        return failure(:merge_conflict,
          "Update from #{@project.default_branch} hit conflicts a human needs to resolve. " \
          "Nothing was pushed.")
      end

      push_pipeline_branch if rev_parse("HEAD") != before
      succeed
    end

    def run_merge
      _out, ok = git("merge", "--no-edit", "origin/#{@project.default_branch}")
      return true if ok

      git("merge", "--abort")
      false
    end

    def succeed
      @pipeline.update!(config: @pipeline.config.except("update_error"))
      Pipelines::BroadcastActions.call(@pipeline)
      Dashboard::Broadcast.call(pipeline: @pipeline, activity: true)
      Result.success(@pipeline)
    end

    # Surface the reason on the pipeline and broadcast the actions card, then
    # report the domain failure.
    def failure(error, message)
      @pipeline.update!(config: @pipeline.config.merge("update_error" => message))
      Pipelines::BroadcastActions.call(@pipeline)
      Result.failure(error, record: @pipeline)
    end

    # --- git working tree (replicates MergeStepBranch/Finalize conventions) --

    def prepare_repo
      FileUtils.mkdir_p(repos_root)
      if Dir.exist?(repo_dir.join(".git"))
        git!("fetch", "origin", "--prune")
      else
        out, ok = run([ "git", "clone", @project.repo_url, repo_dir.to_s ])
        raise UpdateError, "git clone failed: #{out}" unless ok
      end
      # Local identity so the merge commit never depends on ambient git config.
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

    def rev_parse(ref)
      git!("rev-parse", ref).strip
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
      raise UpdateError, "git #{args.first} failed: #{out}" unless ok
      out
    end

    def git(*args, dir: repo_dir)
      run([ "git", "-C", dir.to_s, *args ])
    end

    def run(command)
      out = nil
      status = nil
      Timeout.timeout(GIT_TIMEOUT) { out, status = Open3.capture2e(*command) }
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
    # MergeStepBranch/Finalize use, so all three share one clone per project.
    def url_slug
      @url_slug ||= @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
    end
  end
end
