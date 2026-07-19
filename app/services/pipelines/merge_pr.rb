module Pipelines
  # Merges a finalized pipeline's GitHub PR via the `gh` CLI (Pipelines::Github).
  # The pipeline reaches this state only after Finalize has opened a real PR and
  # stored its number; a local-hub pipeline (compare-link fallback, no pr_number)
  # can't be merged here and the UI never offers the button.
  #
  # Squash is the default strategy: the pipeline branch carries per-step merge
  # commits (finalization strips `.pipeliner/` but doesn't squash them —
  # docs/execution-model.md), so squashing lands the whole pipeline as one clean
  # commit on the default branch. (Documented in docs/execution-model.md.)
  #
  # Domain outcomes are Results. A gh failure — a non-mergeable PR, conflicts,
  # missing auth — is data: the message is surfaced on the pipeline
  # (`config["merge_error"]`) and broadcast, never raised.
  class MergePr
    MERGE_METHOD = "squash".freeze

    def self.call(pipeline:, github: Pipelines::Github)
      new(pipeline:, github:).call
    end

    def initialize(pipeline:, github: Pipelines::Github)
      @pipeline = pipeline
      @project = pipeline.project
      @github = github
    end

    def call
      return Result.failure(:already_merged, record: @pipeline) if @pipeline.merged?
      return failure(:no_pr, "This pipeline has no GitHub PR to merge.") if @pipeline.pr_number.blank?
      return failure(:no_remote, "This project has no GitHub remote.") unless @project.github?
      return failure(:gh_unavailable, "The GitHub CLI is unavailable or not authenticated.") unless @github.ready?

      response = @github.merge_pr(repo: @project.github_slug, number: @pipeline.pr_number, method: MERGE_METHOD)
      return failure(:merge_failed, "Merge failed: #{response.error}") unless response.ok?

      succeed
    end

    private

    def succeed
      @pipeline.update!(status: "merged", config: @pipeline.config.except("merge_error"))
      broadcast
      Result.success(@pipeline)
    end

    # Surface the reason on the pipeline (so a reload and every other tab show it)
    # and broadcast the actions card, then report the domain failure.
    def failure(error, message)
      @pipeline.update!(config: @pipeline.config.merge("merge_error" => message))
      Pipelines::BroadcastActions.call(@pipeline)
      Result.failure(error, record: @pipeline)
    end

    def broadcast
      Pipelines::BroadcastActions.call(@pipeline)
      Pipelines::BroadcastStatus.call(@pipeline)
      Dashboard::Broadcast.call(pipeline: @pipeline, activity: true)
    end
  end
end
