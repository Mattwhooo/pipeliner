class PhasesController < ApplicationController
  def show
    @phase = membership_scoped_phase
    @pipeline = @phase.pipeline
  end

  def send_back
    phase = membership_scoped_phase
    result = Phases::SendBack.call(
      phase: phase,
      user: current_user,
      feedback: params[:feedback].to_s.strip,
      target_step_id: params[:target_step_id].presence
    )

    if result.success?
      redirect_to pipeline_path(phase.pipeline),
        notice: "#{phase.kind.humanize} sent back for more work."
    else
      redirect_to phase_path(phase), alert: send_back_alert(result.error)
    end
  end

  def answers
    phase = membership_scoped_phase
    result = Phases::AnswerQuestions.call(
      phase: phase,
      user: current_user,
      answers: params[:answers].to_s.strip
    )

    if result.success?
      redirect_to pipeline_path(phase.pipeline),
        notice: "Answers sent — Define is iterating on the requirements."
    else
      redirect_to pipeline_path(phase.pipeline), alert: answers_alert(result.error)
    end
  end

  private

  def send_back_alert(error)
    case error
    when :blank_feedback then "Feedback is required to send a phase back."
    when :no_target      then "Pick a step to send this phase back to."
    else "This phase is not awaiting approval."
    end
  end

  def answers_alert(error)
    case error
    when :blank_answers then "Add your answers before sending."
    when :busy          then "Define is still running — wait for the current pass to finish."
    else "This phase can't take answers right now."
    end
  end

  def membership_scoped_phase
    Phase.joins(pipeline: { project: :memberships })
      .where(memberships: { user_id: current_user.id })
      .find(params[:id])
  end
end
