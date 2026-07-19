module Pipelines
  # Creates a pipeline with its four fixed phases (Define → Plan → Build →
  # Review) and its dedicated branch name. Cutting the actual git branch and
  # opening the PR happen in the GitHub integration (later); until then the
  # pipeline stays in "draft".
  class Create
    PHASE_KINDS = Phase::KINDS_IN_ORDER

    # Gate at each phase boundary: Define and Review pause for a human; Plan and
    # Build auto-advance on convergence (docs/execution-model.md — "Gates").
    # Plan's critics (guide alignment, design coverage) are the quality bar
    # between Plan and Build; the human checkpoints are the ask (Define) and
    # the result (Review).
    GATE_MODES = { "define" => "human", "plan" => "auto", "build" => "auto",
      "review" => "human" }.freeze

    # Fallback (no pipeline_template): the standard core of every Define phase,
    # run in this order. Custom define-phase templates run *between* Clarifying
    # Questions and the Completeness Critic — hence "the three core names"
    # excluded from the custom list below.
    CORE_DEFINE_NAMES = [ "Requirements Writer", "Clarifying Questions Writer",
      "Requirements Completeness Critic" ].freeze

    def self.call(project:, title:, initial_prompt: nil)
      new(project:, title:, initial_prompt:).call
    end

    def initialize(project:, title:, initial_prompt:)
      @project = project
      @title = title
      @initial_prompt = initial_prompt
    end

    def call
      public_id = generate_public_id
      pipeline = @project.pipelines.new(
        title: @title,
        initial_prompt: @initial_prompt,
        public_id: public_id,
        branch: "pipeliner/#{public_id}",
        status: "draft",
        current_phase: "define"
      )

      ApplicationRecord.transaction do
        pipeline.save!
        PHASE_KINDS.each_with_index do |kind, index|
          pipeline.phases.create!(kind: kind, position: index + 1,
            gate_mode: GATE_MODES.fetch(kind))
        end
        compose_phases(pipeline)
        start(pipeline)
      end

      Result.success(pipeline)
    rescue ActiveRecord::RecordInvalid
      Result.failure(:invalid, record: pipeline)
    end

    private

    # Define is the interactive pre-phase — it begins immediately on creation so
    # the Manager can tick it (the Manager only advances *running* phases, and
    # there is no separate Start action). current_phase already defaults to
    # define.
    def start(pipeline)
      pipeline.phases.find_by!(kind: "define").update!(status: "running")
      pipeline.update!(status: "running")
    end

    # Auto-compose phases at creation from the project's pipeline_template (the
    # pinned per-phase composition). Define and Plan are always composed; Plan
    # leads with the Workflow Composer, which fills Build and Review later — so
    # those start empty UNLESS the template forbids manager additions and pins
    # build/review steps, in which case they're composed directly here (the
    # composer's later materialization then no-ops on the non-empty phases).
    def compose_phases(pipeline)
      template = @project.pipeline_template
      return compose_from_pack_defaults(pipeline) if template.nil?

      compose_templates(pipeline.phases.find_by!(kind: "define"),
        define_template_list(template))
      compose_templates(pipeline.phases.find_by!(kind: "plan"),
        template_step_templates(template, "plan"))

      unless template.allow_manager_additions
        %w[build review].each do |kind|
          steps = template_step_templates(template, kind)
          compose_templates(pipeline.phases.find_by!(kind: kind), steps) if steps.any?
        end
      end
    end

    # Compose an ordered list of StepTemplates into a phase: AddToWorkflow wires
    # linear depends_on; each critic routes back to the phase's first
    # worker-executed builder (the standard feedback edge).
    def compose_templates(phase, step_templates)
      first_builder = nil
      step_templates.each do |step_template|
        route_to_id = (first_builder.id if step_template.type_critic? && first_builder)
        result = Steps::AddToWorkflow.call(phase: phase, attributes: {},
          template: step_template, route_to_step_id: route_to_id)
        next unless result.success?

        first_builder ||= result.value if result.value.type_builder?
      end
    end

    def template_step_templates(template, kind)
      template.entries_for(kind).includes(:step_template).map(&:step_template)
    end

    # Pinned define entries in order, with non-pinned define-phase custom
    # templates ("run late", ordered by name) inserted just before the trailing
    # pinned critic when there is one, else appended at the end.
    def define_template_list(template)
      pinned = template_step_templates(template, "define")
      late = StepTemplate.available_to(@project).for_phase("define")
        .where.not(id: pinned.map(&:id)).order(:name).to_a

      if pinned.any? && pinned.last.type_critic?
        pinned[0..-2] + late + [ pinned.last ]
      else
        pinned + late
      end
    end

    # --- fallback (project without a pipeline_template) ---------------------

    def compose_from_pack_defaults(pipeline)
      templates_by_name = StepTemplate.available_to(@project).index_by(&:name)

      compose_phase(pipeline.phases.find_by!(kind: "define"),
        define_specs, templates_by_name)
      compose_phase(pipeline.phases.find_by!(kind: "plan"),
        plan_specs, templates_by_name)
    end

    def compose_phase(phase, specs, templates_by_name)
      created = {}
      specs.each do |spec|
        template = templates_by_name[spec[:template]]
        next unless template

        route_to_id = spec[:route_to] && created[spec[:route_to]]&.id
        result = Steps::AddToWorkflow.call(phase: phase, attributes: {},
          template: template, route_to_step_id: route_to_id)
        created[spec[:template]] = result.value if result.success?
      end
    end

    def define_specs
      specs = [ { template: "Requirements Writer" },
                { template: "Clarifying Questions Writer" } ]
      custom_define_names.each { |name| specs << { template: name } }
      specs << { template: "Requirements Completeness Critic",
                 route_to: "Requirements Writer" }
      specs
    end

    def custom_define_names
      StepTemplate.available_to(@project).for_phase("define")
        .where.not(name: CORE_DEFINE_NAMES).order(:name).pluck(:name)
    end

    def plan_specs
      [ { template: "Workflow Composer" },
        { template: "Design Writer" },
        { template: "Guide Alignment Critic", route_to: "Design Writer" },
        { template: "Design Coverage Critic", route_to: "Design Writer" } ]
    end

    def generate_public_id
      loop do
        candidate = "pl_#{SecureRandom.alphanumeric(8).downcase}"
        break candidate unless Pipeline.exists?(public_id: candidate)
      end
    end
  end
end
