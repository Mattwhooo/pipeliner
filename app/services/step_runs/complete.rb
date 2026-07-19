module StepRuns
  # Records a run's completion. Two fences guard correctness (M10):
  #   1. Epoch: a completion is honored only if it carries the current lease's
  #      epoch — a reclaimed/late worker's report is rejected as stale.
  #   2. At-most-one-merge: only one run per (step, iteration, shard) may ever
  #      succeed; a duplicate success (crashed-after-push worker) is rejected
  #      and its branch will not be merged.
  #
  # A third status, "transient", is for infrastructure outages the worker can
  # detect (session/rate limits, API overload): the run is re-queued with
  # backoff instead of failing, so pipelines pause through an outage and resume
  # unattended when it lifts.
  class Complete
    STATUSES = %w[succeeded failed transient].freeze

    # Transient backoff: attempt * 5min, capped at 30min; give up (fail) after
    # MAX_TRANSIENT_ATTEMPTS so a permanent problem misclassified as transient
    # still surfaces to a human.
    TRANSIENT_BACKOFF_STEP = 5.minutes
    TRANSIENT_BACKOFF_CAP = 30.minutes
    MAX_TRANSIENT_ATTEMPTS = 8

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

      return requeue_transient if @status == "transient"

      @step_run.update!(
        state: @status,
        result: @result,
        verdict: @verdict,
        commit_sha: @commit_sha,
        finished_at: Time.current,
        lease_expires_at: nil
      )
      BroadcastCard.call(@step_run)
      # A success may have pushed a step branch — merge it into the pipeline
      # branch (control-plane-only, serialized per pipeline). Failed completions
      # have nothing to merge.
      Pipelines::MergeStepBranchJob.perform_later(@step_run) if @status == "succeeded"
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

    # The outage path: same run, next attempt, claimable only after the backoff
    # window. The worker discarded its local work; the redo starts fresh
    # (at-least-once execution).
    def requeue_transient
      if @step_run.attempt >= MAX_TRANSIENT_ATTEMPTS
        @step_run.update!(
          state: "failed",
          result: { "summary" => "transient-failure retries exhausted " \
            "(#{MAX_TRANSIENT_ATTEMPTS} attempts): #{transient_reason}" },
          finished_at: Time.current,
          lease_expires_at: nil
        )
        BroadcastCard.call(@step_run)
        return Result.success(@step_run)
      end

      backoff = [ TRANSIENT_BACKOFF_STEP * @step_run.attempt, TRANSIENT_BACKOFF_CAP ].min
      @step_run.update!(
        state: "ready",
        attempt: @step_run.attempt + 1,
        worker: nil,
        epoch: nil,
        lease_expires_at: nil,
        started_at: nil,
        progress: nil,
        available_at: backoff.from_now,
        result: { "summary" => "transient (attempt #{@step_run.attempt}, retry in " \
          "#{(backoff / 60).to_i}m): #{transient_reason}" }
      )
      BroadcastCard.call(@step_run)
      Result.success(@step_run)
    end

    def transient_reason
      @result&.dig("summary").presence || "worker reported a transient outage"
    end
  end
end
