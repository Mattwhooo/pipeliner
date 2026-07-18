class ProjectsController < ApplicationController
  def index
    @projects = current_user.projects.order(:name)
  end

  def show
    @project = current_user.projects.find(params[:id])
    @pipelines = @project.pipelines.order(created_at: :desc)
  end

  def new
    @project = Project.new(default_branch: "main", project_type: "software")
  end

  def create
    result = Projects::Create.call(owner: current_user, attributes: project_params)

    if result.success?
      redirect_to result.value, notice: "Project created."
    else
      @project = result.record
      render :new, status: :unprocessable_entity
    end
  end

  private

  def project_params
    params.expect(project: [ :name, :repo_url, :default_branch, :project_type ])
  end
end
