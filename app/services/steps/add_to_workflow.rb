module Steps
  # Adds a step to a phase's workflow (creating the default workflow if the
  # phase has none yet). Fields left blank fall back to the chosen template's
  # defaults. Wires linear ordering automatically: the new step depends_on the
  # previously-last step; critics may declare a route_to target for feedback.
  class AddToWorkflow
    DEFAULT_WORKFLOW_SLUG = "main".freeze

    def self.call(phase:, attributes:, template: nil, route_to_step_id: nil,
      wire_linear: true, workflow: nil)
      new(phase:, attributes:, template:, route_to_step_id:, wire_linear:, workflow:).call
    end

    def initialize(phase:, attributes:, template:, route_to_step_id:, wire_linear: true,
      workflow: nil)
      @phase = phase
      @attributes = attributes.to_h.symbolize_keys
      @template = template
      @route_to_step_id = route_to_step_id
      @wire_linear = wire_linear
      @workflow = workflow
    end

    def call
      step = nil
      ApplicationRecord.transaction do
        # A caller composing several parallel workflows in one phase (the Workflow
        # Planner's split Build) passes the exact workflow to add to; otherwise
        # fall back to the phase's single default workflow.
        workflow = @workflow || @phase.workflows.order(:id).first ||
          @phase.workflows.create!(slug: DEFAULT_WORKFLOW_SLUG)

        previous_last = workflow.steps.order(:position).last

        step = workflow.steps.create!(step_attributes(workflow))

        # A caller composing a non-linear DAG (e.g. Define's decision tree) wires
        # its own depends_on edges; skip the automatic "depends on the previous
        # step" ordering for them.
        if @wire_linear && previous_last
          workflow.step_edges.create!(from_step: previous_last, to_step: step,
            kind: "depends_on")
        end

        if @route_to_step_id.present? && step.type_critic?
          target = workflow.steps.find(@route_to_step_id)
          workflow.step_edges.create!(from_step: step, to_step: target,
            kind: "route_to")
        end
      end

      Result.success(step)
    rescue ActiveRecord::RecordInvalid => e
      Result.failure(:invalid, record: e.record)
    end

    private

    def step_attributes(workflow)
      slug = presence(@attributes[:slug]) || @template&.name&.parameterize
      {
        slug: slug,
        step_type: presence(@attributes[:step_type]) || @template&.step_type,
        role: presence(@attributes[:role]) || @template&.role,
        system_prompt: presence(@attributes[:system_prompt]) || @template&.system_prompt,
        inputs: @template&.default_inputs.presence || [],
        outputs: @template&.default_outputs.presence || [],
        # An explicit scope (a parallel Build workflow's owned paths) overrides
        # the template default so the pre-merge scope check confines this step to
        # its workflow's partition.
        scope: @attributes[:scope].presence || @template&.default_scope,
        step_template: @template,
        position: (workflow.steps.maximum(:position) || 0) + 1
      }
    end

    def presence(value)
      value.presence
    end
  end
end
