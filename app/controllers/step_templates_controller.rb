class StepTemplatesController < ApplicationController
  before_action :set_template, only: [ :edit, :update, :destroy ]

  def index
    @templates = StepTemplate.order(:name)
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

  def template_params
    parsed = params.expect(step_template: [ :name, :step_type, :role, :system_prompt,
      :requirement, :default_inputs_json, :default_outputs_json ])

    attrs = parsed.slice(:name, :step_type, :role, :system_prompt, :requirement).to_h
    attrs[:default_inputs] = parse_json_field(parsed[:default_inputs_json]) if parsed.key?(:default_inputs_json)
    attrs[:default_outputs] = parse_json_field(parsed[:default_outputs_json]) if parsed.key?(:default_outputs_json)
    attrs
  end

  # Inputs/outputs are edited as JSON in the form; blank means [].
  def parse_json_field(raw)
    return [] if raw.blank?
    JSON.parse(raw)
  rescue JSON::ParserError
    []
  end
end
