class PipelineTemplateStepsController < ApplicationController
  before_action :set_template

  def create
    phase = params.dig(:pipeline_template_step, :phase)
    entry = @template.pipeline_template_steps.new(
      step_template_id: params.dig(:pipeline_template_step, :step_template_id),
      phase: phase,
      position: (@template.entries_for(phase).maximum(:position) || 0) + 1
    )

    if entry.save
      redirect_to project_pipeline_template_path(@project), notice: "Step pinned."
    else
      redirect_to project_pipeline_template_path(@project),
        alert: "Could not pin step: #{entry.errors.full_messages.to_sentence}"
    end
  end

  def destroy
    @template.pipeline_template_steps.find(params[:id]).destroy!
    redirect_to project_pipeline_template_path(@project), notice: "Step unpinned."
  end

  def move
    result = PipelineTemplates::MoveStep.call(
      entry: @template.pipeline_template_steps.find(params[:id]),
      direction: params[:direction]
    )
    alert = result.failure? ? "Could not move step." : nil
    redirect_to project_pipeline_template_path(@project), alert: alert
  end

  private

  def set_template
    @project = current_user.projects.find(params[:project_id])
    @template = @project.pipeline_template || @project.create_pipeline_template!
  end
end
