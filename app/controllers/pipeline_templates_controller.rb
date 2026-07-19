class PipelineTemplatesController < ApplicationController
  def show
    @project = authorized_project
    @template = @project.pipeline_template || @project.create_pipeline_template!
  end

  def update
    project = authorized_project
    project.pipeline_template.update!(template_params)
    redirect_to project_pipeline_template_path(project), notice: "Template updated."
  end

  private

  def authorized_project
    current_user.projects.find(params[:project_id])
  end

  def template_params
    params.expect(pipeline_template: [ :allow_manager_additions ])
  end
end
