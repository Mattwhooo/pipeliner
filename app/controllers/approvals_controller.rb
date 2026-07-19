class ApprovalsController < ApplicationController
  def create
    phase = Phase.joins(pipeline: { project: :memberships })
      .where(memberships: { user_id: current_user.id })
      .find(params[:phase_id])

    result = Phases::Approve.call(phase: phase, user: current_user,
      note: params[:note].presence)

    if result.success?
      redirect_to pipeline_path(phase.pipeline),
        notice: "#{phase.kind.humanize} approved#{phase.pipeline.reload.completed? ? " — pipeline complete" : ""}."
    else
      redirect_to pipeline_path(phase.pipeline),
        alert: "This phase is not awaiting approval."
    end
  end
end
