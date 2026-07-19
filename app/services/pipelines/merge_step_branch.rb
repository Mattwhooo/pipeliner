require "open3"
require "timeout"
require "fileutils"

module Pipelines
  # Merges one succeeded step_run's pushed `step/**` branch into its pipeline
  # branch — the control-plane half of branch-per-step (docs/architecture.md,
  # docs/worker.md). Workers only ever push their own step branch; nothing else
  # lands their work on the pipeline branch, so without this step later steps'
  # worktrees never see earlier steps' artifacts.
  #
  # Flow (all git in a control-plane-private clone under tmp/repos/<slug>):
  #   1. Guard: at-most-one-merge per (step, iteration, shard); no-op when the
  #      worker reported no changes (commit_sha nil).
  #   2. Refresh the clone, check out the pipeline branch, fetch the step branch.
  #   3. PRE-MERGE SCOPE CHECK (authoritative — GitHub can't enforce per-path
  #      scope): reject the merge if the diff strays outside the step's declared
  #      scope. A bad commit can sit on an ephemeral step branch but never merge.
  #   4. Merge --no-ff, push, delete the remote step branch, index outputs.
  #
  # Failures are data (Result), except genuinely exceptional git/infra errors
  # (clone/fetch/push) which raise MergeError so the job surfaces + retries them.
  class MergeStepBranch
    # git's well-known empty tree — a sane diff base when two histories share no
    # common ancestor (shouldn't happen, but keeps the scope check total).
    EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904".freeze
    GIT_TIMEOUT = 120 # seconds — generous for a fetch/clone, bounded for a hang.

    class MergeError < StandardError; end

    def self.call(step_run:)
      new(step_run:).call
    end

    def initialize(step_run:)
      @step_run = step_run
      @step = step_run.step
      @workflow = @step.workflow
      @phase = @workflow.phase
      @pipeline = @phase.pipeline
      @project = @pipeline.project
    end

    def call
      return Result.failure(:already_merged, record: @step_run) if @step_run.merged?
      return Result.failure(:not_succeeded, record: @step_run) unless @step_run.succeeded?
      return Result.failure(:duplicate, record: @step_run) if duplicate_merge?
      return no_op_success if @step_run.commit_sha.blank?

      # A single project clone is shared across that project's pipelines, but
      # merges are only serialized per pipeline (the job's concurrency key). An
      # OS-level lock keeps two pipelines of the same project off the same
      # working tree at once.
      with_repo_lock { merge! }
    end

    private

    # --- orchestration ------------------------------------------------------

    def merge!
      prepare_repo
      checkout_pipeline_branch
      step_sha = fetch_step_branch

      offending = out_of_scope_paths(step_sha)
      return fail_run(:scope_violation, "scope violation: #{offending.join(", ")}") if offending.any?

      return fail_run(:merge_conflict, "merge conflict") unless run_merge(step_sha)

      push_pipeline_branch
      delete_remote_step_branch
      merge_commit = rev_parse("HEAD")

      ApplicationRecord.transaction do
        index_artifacts(merge_commit)
        @step_run.update!(merged_at: Time.current, merge_error: nil)
      end
      StepRuns::BroadcastCard.call(@step_run)
      materialize_workflow_plan
      Result.success(@step_run)
    end

    # A merged Workflow Composer run carries a `workflow_plan` output artifact;
    # its plan composes the Build/Review steps. MaterializePlan's own failures
    # are Results (it records a ManagerDecision), so we don't observe them here
    # and the merge's flow stays unchanged.
    def materialize_workflow_plan
      return unless declared_outputs.any? { |output| output["artifact"] == "workflow_plan" }

      Workflows::MaterializePlan.call(step_run: @step_run)
    end

    def no_op_success
      @step_run.update!(merged_at: Time.current, merge_error: nil)
      StepRuns::BroadcastCard.call(@step_run)
      Result.success(@step_run)
    end

    def fail_run(error, message)
      @step_run.update!(state: "failed", merge_error: message)
      StepRuns::BroadcastCard.call(@step_run)
      Result.failure(error, record: @step_run)
    end

    def duplicate_merge?
      StepRun
        .where(step_id: @step_run.step_id, iteration: @step_run.iteration,
          shard_key: @step_run.shard_key, state: "succeeded")
        .where.not(id: @step_run.id)
        .where.not(merged_at: nil)
        .exists?
    end

    # --- git working tree ---------------------------------------------------

    def prepare_repo
      FileUtils.mkdir_p(repos_root)
      if Dir.exist?(repo_dir.join(".git"))
        git!("fetch", "origin", "--prune")
      else
        out, ok = run([ "git", "clone", @project.repo_url, repo_dir.to_s ])
        raise MergeError, "git clone failed: #{out}" unless ok
      end
      # Local identity so the merge commit never depends on ambient git config.
      git!("config", "user.email", "control-plane@pipeliner.local")
      git!("config", "user.name", "Pipeliner Control Plane")
    end

    # Reset the local pipeline branch to origin's (or branch it off the default
    # branch the first time). The clone is control-plane-private, so checking it
    # out is safe.
    def checkout_pipeline_branch
      start = if remote_has_branch?(@pipeline.branch)
        "origin/#{@pipeline.branch}"
      else
        "origin/#{@project.default_branch}"
      end
      git!("checkout", "-B", @pipeline.branch, start)
    end

    def fetch_step_branch
      git!("fetch", "origin", @step_run.step_branch)
      rev_parse("FETCH_HEAD")
    end

    def run_merge(step_sha)
      _out, ok = git("merge", "--no-ff", "-m", merge_message, step_sha)
      return true if ok

      git("merge", "--abort")
      false
    end

    def merge_message
      "Merge step #{@step.slug} (iteration #{@step_run.iteration})"
    end

    def push_pipeline_branch
      git!("push", "origin", @pipeline.branch)
    end

    def delete_remote_step_branch
      # Best-effort cleanup — a failure here (already gone, race) is harmless.
      git("push", "origin", "--delete", @step_run.step_branch)
    end

    def remote_has_branch?(branch)
      out, ok = git("ls-remote", "--heads", "origin", branch)
      ok && out.strip.present?
    end

    def rev_parse(ref)
      git!("rev-parse", ref).strip
    end

    # --- scope check --------------------------------------------------------

    def out_of_scope_paths(step_sha)
      base, ok = git("merge-base", @pipeline.branch, step_sha)
      diff_base = ok && base.strip.present? ? base.strip : EMPTY_TREE
      out = git!("diff", "--name-only", diff_base, step_sha)
      changed = out.split("\n").map(&:strip).reject(&:blank?)
      changed.reject { |path| path_allowed?(path) }
    end

    # A path may change iff it is (a) inside this step's own .pipeliner subtree,
    # or (b) the step declares a `repo` output and either has no scope paths (any
    # repo file) or the path matches one. FNM_PATHNAME is intentionally omitted
    # so a `*` in a scope glob crosses `/` (pragmatic: "app/**" matches nested
    # paths) — see docs/worker.md pre-merge scope check.
    def path_allowed?(path)
      return true if path.start_with?(pipeliner_prefix)
      return false unless repo_output?
      return true if scope_paths.blank?

      scope_paths.any? { |pattern| File.fnmatch(pattern, path, File::FNM_EXTGLOB) }
    end

    def pipeliner_prefix
      position = @phase.position.to_s.rjust(2, "0")
      ".pipeliner/phases/#{position}-#{@phase.kind}/#{@workflow.slug}/#{@step.slug}/"
    end

    def repo_output?
      declared_outputs.any? { |output| output["kind"] == "repo" }
    end

    def scope_paths
      Array(@step.scope&.dig("paths")).presence
    end

    # --- artifact indexing --------------------------------------------------

    def index_artifacts(commit_sha)
      declared_outputs.each do |output|
        name = output["artifact"].presence
        next unless name

        ref = @pipeline.artifact_refs.find_or_initialize_by(
          phase_kind: @phase.kind,
          workflow_slug: @workflow.slug,
          step_slug: @step.slug,
          name: name
        )
        ref.update!(
          kind: output["kind"].presence || "artifact",
          path: output["path"],
          commit_sha: commit_sha
        )
      end
    end

    def declared_outputs
      Array(@step.outputs).select { |output| output.is_a?(Hash) }
    end

    # --- shelling out -------------------------------------------------------

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
      raise MergeError, "git #{args.first} failed: #{out}" unless ok
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

    # Deterministic, filesystem-safe directory name per project repo (repo_url is
    # unique), so a project reuses one clone across merges.
    def url_slug
      @url_slug ||= @project.repo_url.gsub(/\W+/, "-").gsub(/\A-+|-+\z/, "").downcase
    end
  end
end
