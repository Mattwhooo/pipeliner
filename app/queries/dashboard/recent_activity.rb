module Dashboard
  # Merged, time-ordered activity feed across a user's projects — no
  # persisted event/audit table exists, so this composes from the record
  # types that already carry notable moments (R19).
  class RecentActivity
    LIMIT = 15

    # `phase` is set for phase-scoped events so the view can link to
    # `phase_path` instead of `pipeline_path` (R22); nil otherwise.
    Event = Struct.new(:kind, :pipeline, :project, :phase, :description,
                        :occurred_at, keyword_init: true)

    def initialize(user)
      @user = user
    end

    def call
      (approval_events + rework_events + manager_events + step_completion_events)
        .sort_by { |event| -event.occurred_at.to_i }
        .first(LIMIT)
    end

    private

    # Approval (decision: approve) on a Review phase reads as "pipeline
    # finished" rather than generic "Review approved."
    #
    # Each source below is bounded to its own top-LIMIT at the DB (not just
    # the final merged list) — otherwise a query with no LIMIT or time window
    # materializes every matching row ever recorded, and the working set grows
    # unbounded with a project's history. Limiting each source to LIMIT is
    # still correct: the global top-LIMIT can never need more than LIMIT rows
    # from any single source.
    def approval_events
      Approval.joins(phase: { pipeline: { project: :memberships } })
        .where(memberships: { user_id: @user.id }, decision: "approve")
        .includes(phase: { pipeline: :project })
        .order(created_at: :desc).limit(LIMIT)
        .map { |approval| describe_approval(approval) }
    end

    # "consensus" (auto-gate approved a phase) or "escalate" (parked for a
    # human) — "route_to" entries are per-iteration routing noise, excluded.
    def manager_events
      ManagerDecision.where(decision: %w[consensus escalate])
        .joins(phase: { pipeline: { project: :memberships } })
        .where(memberships: { user_id: @user.id })
        .includes(phase: { pipeline: :project })
        .order(created_at: :desc).limit(LIMIT)
        .map { |decision| describe_decision(decision) }
    end

    def rework_events
      ReworkEvent.joins(pipeline: { project: :memberships })
        .where(memberships: { user_id: @user.id })
        .includes(:from_phase, :target_phase, pipeline: :project)
        .order(created_at: :desc).limit(LIMIT)
        .map { |rework| describe_rework(rework) }
    end

    # A run reaching a terminal state — "a piece of work completing" (R19).
    def step_completion_events
      StepRun.where(state: %w[succeeded failed]).where.not(finished_at: nil)
        .joins(step: { workflow: { phase: { pipeline: { project: :memberships } } } })
        .where(memberships: { user_id: @user.id })
        .includes(step: { workflow: { phase: :pipeline } })
        .order(finished_at: :desc).limit(LIMIT)
        .map { |run| describe_step_run(run) }
    end

    def describe_approval(approval)
      phase = approval.phase
      pipeline = phase.pipeline
      description = phase.review_phase? ? "#{pipeline.title} finished" : "#{phase.kind.humanize} approved for #{pipeline.title}"
      Event.new(kind: :approval, pipeline: pipeline, project: pipeline.project, phase: phase,
        description: description, occurred_at: approval.created_at)
    end

    def describe_decision(decision)
      phase = decision.phase
      pipeline = phase.pipeline
      description = if decision.escalate_decision?
        "#{phase.kind.humanize} escalated to a human for #{pipeline.title}"
      else
        "#{phase.kind.humanize} reached consensus for #{pipeline.title}"
      end
      Event.new(kind: :manager_decision, pipeline: pipeline, project: pipeline.project, phase: phase,
        description: description, occurred_at: decision.created_at)
    end

    def describe_rework(rework)
      pipeline = rework.pipeline
      description = "#{pipeline.title} sent back from #{rework.from_phase.kind.humanize} to #{rework.target_phase.kind.humanize}"
      Event.new(kind: :rework, pipeline: pipeline, project: pipeline.project,
        description: description, occurred_at: rework.created_at)
    end

    def describe_step_run(run)
      step = run.step
      pipeline = step.workflow.phase.pipeline
      verb = run.succeeded? ? "completed" : "failed"
      description = "#{step.slug.humanize} #{verb} in #{pipeline.title}"
      Event.new(kind: :step_run, pipeline: pipeline, project: pipeline.project,
        description: description, occurred_at: run.finished_at)
    end
  end
end
