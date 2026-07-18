module StepRuns
  # Records a run's completion. Two fences guard correctness (M10):
  #   1. Epoch: a completion is honored only if it carries the current lease's
  #      epoch — a reclaimed/late worker's report is rejected as stale.
  #   2. At-most-one-merge: only one run per (step, iteration, shard) may ever
  #      succeed; a duplicate success (crashed-after-push worker) is rejected
  #      and its branch will not be merged.
  # The actual branch merge happens in the GitHub integration; this service is
  # the gate it will sit behind.
  class Complete
    STATUSES = %w[succeeded failed].freeze

    def self.call(step_run:, worker:, epoch:, status:, result: nil, verdict: nil, commit_sha: nil)
      new(step_run:, worker:, epoch:, status:, result:, verdict:, commit_sha:).call
    end

    def initialize(step_run:, worker:, epoch:, status:, result:, verdict:, commit_sha:)
      @step_run = step_run
      @worker = worker
      @epoch = epoch
      @status = status.to_s
      @result = result
      @verdict = verdict
      @commit_sha = commit_sha
    end

    def call
      return Result.failure(:invalid_status) unless @status.in?(STATUSES)
      return Result.failure(:stale_epoch) unless current_lease?
      return Result.failure(:duplicate_completion) if already_succeeded_elsewhere?

      @step_run.update!(
        state: @status,
        result: @result,
        verdict: @verdict,
        commit_sha: @commit_sha,
        finished_at: Time.current,
        lease_expires_at: nil
      )
      BroadcastCard.call(@step_run)
      Result.success(@step_run)
    end

    private

    def current_lease?
      @step_run.worker_id == @worker.id &&
        @step_run.epoch == @epoch &&
        @step_run.state.in?(%w[claimed running])
    end

    def already_succeeded_elsewhere?
      @status == "succeeded" &&
        StepRun.where(
          step_id: @step_run.step_id,
          iteration: @step_run.iteration,
          shard_key: @step_run.shard_key,
          state: "succeeded"
        ).where.not(id: @step_run.id).exists?
    end
  end
end
