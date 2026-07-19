class ApprovalsController < ApplicationController
  def create
    phase = Phase.joins(pipeline: { project: :memberships })
      .where(memberships: { user_id: current_user.id })
      .find(params[:phase_id])

    result = Phases::Approve.call(phase: phase, user: current_user,
      note: params[:note].presence, context: params[:context].presence)

    if result.success?
      redirect_to pipeline_path(phase.pipeline),
        notice: "#{phase.kind.humanize} approved#{result.value.completed? ? " — pipeline complete" : ""}."
    else
      redirect_to pipeline_path(phase.pipeline), alert: approval_alert(result.error)
    end
  end

  private

  def approval_alert(error)
    case error
    when :not_settled then "Define isn't ready to finish yet — keep using the menu until it settles."
    else "This phase is not awaiting approval."
    end
  end
end
