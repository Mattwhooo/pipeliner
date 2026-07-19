require "json"

module Workflows
  # Materializes the Workflow Composer's plan (a planner step's `workflow_plan`
  # artifact) into real Build and Review steps (docs/execution-model.md —
  # "Workflow composition (configurable + agentic)"). The composer decides which
  # steps this task needs and in what order; this service turns that decision
  # into Steps wired with linear `depends_on` edges and critic `route_to` edges.
  #
  # Input: the composer's succeeded+merged step_run. Its plan is read from
  # `run.result["artifacts"]["workflow_plan"]` (the worker mirrors declared
  # output artifacts there), so no git access is needed.
  #
  # The project's pipeline_template constrains the result:
  #   * Pinned build/review entries are always materialized (in pinned order),
  #     even if the plan omits them — the plan's extras follow, duplicates
  #     skipped.
  #   * When allow_manager_additions is false, plan entries beyond the pinned
  #     set are ignored (pinned-only materialization).
  #
  # Idempotent: a phase whose workflow already has steps is left untouched, so a
  # re-merge (or a re-run of this service) never duplicates steps. A malformed
  # plan or a plan naming an unknown template (when additions are allowed)
  # materializes NOTHING and records a ManagerDecision "escalate" on the Plan
  # phase explaining the bad plan.
  class MaterializePlan
    # Ordering of the two composed phases (the plan's top-level keys).
    PHASE_KEYS = { "build" => "build", "review" => "review" }.freeze

    # Raised internally to roll the materialization transaction back and fail.
    class Rollback < StandardError; end

    def self.call(step_run:)
      new(step_run:).call
    end

    def initialize(step_run:)
      @step_run = step_run
      @step = step_run.step
      @plan_phase = @step.workflow.phase
      @pipeline = @plan_phase.pipeline
      @project = @pipeline.project
      @pipeline_template = @project.pipeline_template
      @allow_additions = @pipeline_template.nil? || @pipeline_template.allow_manager_additions
    end

    def call
      plan = parse_plan
      return invalid_plan("Workflow Composer plan is missing or not valid JSON.") if plan.nil?

      templates_by_name = StepTemplate.available_to(@project).index_by(&:name)
      targets = []       # [[phase, specs], ...]
      unknown = []
      ignored = 0

      PHASE_KEYS.each do |key, kind|
        phase = @pipeline.phases.find_by(kind: kind)
        next unless phase && phase_empty?(phase)

        specs, phase_unknown, phase_ignored =
          build_specs(kind, plan_entries(plan[key]), templates_by_name)
        unknown.concat(phase_unknown)
        ignored += phase_ignored
        targets << [ phase, specs ] if specs.any?
      end

      # An unknown template invalidates the whole plan — but only additions can
      # be unknown, so a pinned-only (additions-disabled) materialization never
      # trips this.
      if unknown.any?
        return invalid_plan("Workflow Composer plan names unknown templates: " \
          "#{unknown.uniq.join(", ")}.")
      end

      return Result.success(@step_run) if targets.empty?

      created = []
      ApplicationRecord.transaction do
        targets.each { |phase, specs| created.concat(materialize_phase(phase, specs)) }
      end

      return Result.success(@step_run) if created.empty?

      record_success(created, ignored)
      broadcast(created.map { |step| step.workflow.phase }.uniq)
      Result.success(@step_run)
    rescue Rollback
      invalid_plan("Workflow Composer plan could not be materialized " \
        "(duplicate or invalid step definition).")
    end

    private

    # --- plan parsing -------------------------------------------------------

    def parse_plan
      raw = @step_run.result.is_a?(Hash) ? @step_run.result.dig("artifacts", "workflow_plan") : nil
      return nil if raw.blank?

      parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def plan_entries(value)
      Array(value).select { |entry| entry.is_a?(Hash) && entry["template"].present? }
    end

    def phase_empty?(phase)
      phase.workflows.none? { |workflow| workflow.steps.exists? }
    end

    # --- spec building (pinned merge + additions policy) --------------------

    # Returns [specs, unknown_names, ignored_count] for one phase. A spec is
    # { template: StepTemplate, route_to_name: <name or nil> }. Pinned templates
    # come first (in pinned order); plan entries that aren't pinned follow, and
    # are either included (additions allowed) or counted as ignored (disallowed).
    def build_specs(kind, entries, templates_by_name)
      specs = []
      seen = {}

      pinned_templates(kind).each do |step_template|
        match = entries.find { |e| e["template"] == step_template.name }
        specs << { template: step_template, route_to_name: match && match["route_to"] }
        seen[step_template.name] = true
      end

      unknown = []
      ignored = 0
      entries.each do |entry|
        name = entry["template"]
        next if seen[name]

        if @allow_additions
          template = templates_by_name[name]
          if template.nil?
            unknown << name
          else
            specs << { template: template, route_to_name: entry["route_to"] }
            seen[name] = true
          end
        else
          ignored += 1
        end
      end

      [ specs, unknown, ignored ]
    end

    def pinned_templates(kind)
      return [] unless @pipeline_template

      @pipeline_template.entries_for(kind).includes(:step_template).map(&:step_template)
    end

    # --- materialization ----------------------------------------------------

    # Composes one phase's specs into steps. A critic routes to the step created
    # for its explicit route_to name; failing that (e.g. a pinned critic with no
    # plan-supplied target), it falls back to the phase's first builder.
    def materialize_phase(phase, specs)
      created_by_name = {}
      first_builder = nil

      specs.map do |spec|
        route_to_id = spec[:route_to_name] && created_by_name[spec[:route_to_name]]&.id
        route_to_id ||= first_builder&.id if spec[:template].type_critic?

        result = Steps::AddToWorkflow.call(phase: phase, attributes: {},
          template: spec[:template], route_to_step_id: route_to_id)
        raise Rollback unless result.success?

        step = result.value
        created_by_name[spec[:template].name] = step
        first_builder ||= step if step.type_builder?
        step
      end
    end

    # --- outcomes -----------------------------------------------------------

    def record_success(created, ignored)
      build_count = created.count { |step| step.workflow.phase.build_phase? }
      review_count = created.size - build_count
      rationale = "Workflow Composer materialized #{build_count} build + " \
        "#{review_count} review step(s)."
      if ignored.positive?
        rationale += " Ignored #{ignored} manager addition(s) beyond the pinned " \
          "set (additions are disabled for this project)."
      end
      @plan_phase.manager_decisions.create!(
        decision: "route_to",
        iteration: @step_run.iteration,
        route_to: created.map(&:slug),
        rationale: rationale
      )
    end

    def invalid_plan(reason)
      @plan_phase.manager_decisions.create!(
        decision: "escalate",
        iteration: @step_run.iteration,
        rationale: "#{reason} Nothing was materialized; the Plan phase needs a " \
          "human to fix or re-run the Workflow Composer."
      )
      Result.failure(:invalid_plan, record: @step_run)
    end

    def broadcast(phases)
      phases.each { |phase| Phases::BroadcastColumn.call(phase) }
    end
  end
end
