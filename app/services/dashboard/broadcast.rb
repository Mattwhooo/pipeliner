module Dashboard
  # Fans a pipeline-scoped state change out to every user who can see it (its
  # project's members) on their personal dashboard stream. The dashboard has
  # no stream of its own to broadcast to — this is the one place a
  # pipeline-scoped event becomes N per-user pushes.
  class Broadcast
    def self.call(pipeline:, activity: false)
      new(pipeline:, activity:).call
    end

    def initialize(pipeline:, activity:)
      @pipeline = pipeline
      @activity = activity
    end

    def call
      members.each do |user|
        broadcast_pipeline_row(user)
        broadcast_summary(user)
        broadcast_activity(user) if @activity
      end
    end

    private

    def members
      User.joins(:memberships).where(memberships: { project_id: @pipeline.project_id }).distinct
    end

    # Rendered synchronously (not `_later_to`): the locals here are POROs
    # (Dashboard::ActivePipelines::Row/Data, RecentActivity::Event) computed
    # right above, not ActiveRecord objects — they aren't GlobalID-serializable,
    # so they can't cross the ActiveJob argument boundary the async variant
    # uses. Rendering in-process avoids that boundary entirely.
    def broadcast_pipeline_row(user)
      target = ActionView::RecordIdentifier.dom_id(@pipeline, :dashboard_row)
      row = Dashboard::ActivePipelines.new(user).row_for(@pipeline)
      if row
        Turbo::StreamsChannel.broadcast_replace_to([ user, :dashboard ], target: target,
          partial: "home/pipeline_row", locals: { row: row })
      else
        Turbo::StreamsChannel.broadcast_remove_to([ user, :dashboard ], target: target)
      end
    end

    def broadcast_summary(user)
      Turbo::StreamsChannel.broadcast_replace_to([ user, :dashboard ], target: "dashboard-summary",
        partial: "home/summary", locals: { active: Dashboard::ActivePipelines.new(user).call, fleet: Dashboard::FleetHealth.new.call })
    end

    def broadcast_activity(user)
      Turbo::StreamsChannel.broadcast_replace_to([ user, :dashboard ], target: "recent-activity",
        partial: "home/recent_activity", locals: { events: Dashboard::RecentActivity.new(user).call })
    end
  end
end
