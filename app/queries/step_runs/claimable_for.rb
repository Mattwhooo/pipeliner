module StepRuns
  # Ready runs this worker is eligible to claim (role-based matching), oldest
  # first. The operational SKIP LOCKED locking lives here so it has exactly one
  # home (see guides/backend-guide.md).
  class ClaimableFor
    def initialize(worker)
      @worker = worker
    end

    def relation
      StepRun.where(state: "ready", required_role: @worker.supported_roles)
        .where(available_at: nil).or(
          StepRun.where(state: "ready", required_role: @worker.supported_roles)
            .where(available_at: ..Time.current)
        )
        .order(:created_at)
    end

    # Must be called inside a transaction.
    def first_with_lock
      relation.lock("FOR UPDATE SKIP LOCKED").first
    end
  end
end
