class StepTemplatesController < ApplicationController
  before_action :set_template, only: [ :edit, :update, :destroy ]

  def index
    # Global templates plus those scoped to the current user's projects.
    @templates = StepTemplate.where(project_id: [ nil, *current_user.project_ids ])
      .includes(:project).order(:name)
  end

  def new
    @template = StepTemplate.new(requirement: "conditional")
  end

  def create
    @template = StepTemplate.new(template_params)
    if @template.save
      redirect_to step_templates_path, notice: "Template created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @template.update(template_params)
      redirect_to step_templates_path, notice: "Template updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @template.destroy!
    redirect_to step_templates_path, notice: "Template deleted."
  end

  private

  def set_template
    @template = StepTemplate.find(params[:id])
  end

  # Artifact inputs/outputs are deliberately NOT editable here: artifact names
  # and paths are the rigid inter-phase contract (docs/artifact-schema.md).
  # They come from the template pack / code, not free-typed JSON.
  def template_params
    params.expect(step_template: [ :name, :step_type, :role, :system_prompt, :requirement, :phase, :project_id ])
  end
end
