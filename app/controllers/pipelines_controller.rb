class PipelinesController < ApplicationController
  def index
    @pipelines = Pipeline.joins(project: :memberships)
      .where(memberships: { user_id: current_user.id })
      .includes(:project).order(created_at: :desc)
  end

  def show
    @pipeline = Pipeline.joins(project: :memberships)
      .where(memberships: { user_id: current_user.id })
      .find(params[:id])
    @phases = @pipeline.phases.includes(workflows: { steps: { step_runs: :worker } })
  end

  def new
    @project = current_user.projects.find(params[:project_id])
    @pipeline = @project.pipelines.new
  end

  def create
    @project = current_user.projects.find(params[:project_id])
    result = Pipelines::Create.call(
      project: @project,
      title: pipeline_params[:title],
      initial_prompt: pipeline_params[:initial_prompt]
    )

    if result.success?
      redirect_to result.value, notice: "Pipeline created."
    else
      @pipeline = result.record
      render :new, status: :unprocessable_entity
    end
  end

  private

  def pipeline_params
    params.expect(pipeline: [ :title, :initial_prompt ])
  end
end
