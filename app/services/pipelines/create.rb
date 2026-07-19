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

    # Compose Define at creation as the fixed decision tree (below); Plan, Build
    # and Review start EMPTY and are materialized later by Define's Workflow
    # Planner (Workflows::MaterializePlan). The one exception: a project that
    # forbids manager additions gets its pinned plan/build/review steps composed
    # directly here, so the planner's later materialization no-ops on them.
    def compose_phases(pipeline)
      compose_define_tree(pipeline.phases.find_by!(kind: "define"))

      template = @project.pipeline_template
      return if template.nil? || template.allow_manager_additions

      %w[plan build review].each do |kind|
        steps = template_step_templates(template, kind)
        compose_templates(pipeline.phases.find_by!(kind: kind), steps) if steps.any?
      end
    end

    # The Define decision tree (docs/execution-model.md — "Define decision
    # tree"). A fixed, ordered set of steps wired with explicit DAG edges:
    #
    #   Code Explorer ─depends_on▶ Clarifying Questions ─depends_on▶ Requirements
    #     Writer ─depends_on▶ Workflow Planner ─depends_on▶ Define Review
    #
    #   Clarifying Questions (a critic) ─route_to▶ Human Feedback ─route_to▶
    #     Clarifying Questions   (the human-in-the-loop clarification loop)
    #
    # The linear depends_on chain only advances PAST Clarifying Questions once it
    # PASSES (ManagerTick#predecessor_satisfied?), so nothing downstream runs
    # until the task is fully defined. Human Feedback sits OFF the chain (reached
    # only via route_to), so it never blocks the forward path.
    DEFINE_STEP_NAMES = {
      explorer: "Code Explorer",
      clarifying: "Clarifying Questions",
      human: "Human Feedback",
      requirements: "Requirements Writer",
      planner: "Workflow Planner",
      review: "Define Review"
    }.freeze

    DEFINE_DEPENDS_ON = [
      [ :explorer, :clarifying ], [ :clarifying, :requirements ],
      [ :requirements, :planner ], [ :planner, :review ]
    ].freeze

    DEFINE_ROUTE_TO = [ [ :clarifying, :human ], [ :human, :clarifying ] ].freeze

    def compose_define_tree(phase)
      templates = StepTemplate.available_to(@project).index_by(&:name)
      steps = {}
      DEFINE_STEP_NAMES.each do |key, name|
        template = templates[name]
        next unless template

        result = Steps::AddToWorkflow.call(phase: phase, attributes: {},
          template: template, wire_linear: false)
        steps[key] = result.value if result.success?
      end
      wire_define_edges(steps)
    end

    def wire_define_edges(steps)
      workflow = steps.values.first&.workflow
      return unless workflow

      DEFINE_DEPENDS_ON.each { |from, to| add_edge(workflow, steps, from, to, "depends_on") }
      DEFINE_ROUTE_TO.each { |from, to| add_edge(workflow, steps, from, to, "route_to") }
    end

    def add_edge(workflow, steps, from_key, to_key, kind)
      from = steps[from_key]
      to = steps[to_key]
      return unless from && to

      workflow.step_edges.create!(from_step: from, to_step: to, kind: kind)
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

    def generate_public_id
      loop do
        candidate = "pl_#{SecureRandom.alphanumeric(8).downcase}"
        break candidate unless Pipeline.exists?(public_id: candidate)
      end
    end
  end
end
