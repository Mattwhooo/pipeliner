class HomeController < ApplicationController
  def index
    @active   = safely { Dashboard::ActivePipelines.new(current_user).call }
    @activity = safely { Dashboard::RecentActivity.new(current_user).call }
    @fleet    = safely { Dashboard::FleetHealth.new.call }
  end

  # Own action so the fleet panel is independently pollable without
  # re-rendering the whole dashboard.
  def fleet_health
    render partial: "home/fleet_health_frame", locals: { fleet: Dashboard::FleetHealth.new.call }
  end

  private

  # Presentation-boundary rescue (guides/backend-guide.md, "Errors &
  # results"): a multi-panel aggregate view may wrap each independent panel's
  # single read so one panel's infrastructure failure doesn't 500 the whole
  # page. Each block below is the query's ONE read (`.call`) — no reads
  # happen later, in the view.
  def safely
    yield
  rescue StandardError => e
    Rails.logger.error("[dashboard] #{e.class}: #{e.message}")
    nil
  end
end
