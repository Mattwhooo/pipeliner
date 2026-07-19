class StepsController < ApplicationController
  def new
    @phase = authorized_phase(params[:phase_id])
    @templates = StepTemplate.available_to(@phase.pipeline.project)
      .for_phase(@phase.kind).order(:name)
    @existing_steps = @phase.workflows.flat_map(&:steps)
  end

  def create
    @phase = authorized_phase(params[:phase_id])
    template = StepTemplate.find_by(id: params.dig(:step, :step_template_id))

    result = Steps::AddToWorkflow.call(
      phase: @phase,
      attributes: step_params,
      template: template,
      route_to_step_id: params.dig(:step, :route_to_step_id)
    )

    if result.success?
      redirect_to pipeline_path(@phase.pipeline), notice: "Step added."
    else
      redirect_to new_phase_step_path(@phase),
        alert: "Could not add step: #{result.record&.errors&.full_messages&.to_sentence}"
    end
  end

  def queue_run
    step = Step.joins(workflow: { phase: { pipeline: { project: :memberships } } })
      .where(memberships: { user_id: current_user.id })
      .find(params[:id])

    result = StepRuns::Queue.call(step: step)
    pipeline = step.workflow.phase.pipeline

    if result.success?
      redirect_to pipeline_path(pipeline), notice: "Run queued for #{step.slug}."
    else
      redirect_to pipeline_path(pipeline),
        alert: "Could not queue run: #{result.error.to_s.humanize.downcase}."
    end
  end

  private

  def authorized_phase(phase_id)
    Phase.joins(pipeline: { project: :memberships })
      .where(memberships: { user_id: current_user.id })
      .find(phase_id)
  end

  def step_params
    params.expect(step: [ :slug, :step_type, :role, :system_prompt ])
  end
end
