require "json"

module Workflows
  # Materializes the Workflow Planner's plan (a planner step's `workflow_plan`
  # artifact) into real Plan, Build and Review steps (docs/execution-model.md —
  # "Workflow composition (configurable + agentic)"). The planner runs LAST in
  # Define (it was moved out of the Plan phase) and composes every downstream
  # phase at once; this service turns that decision into Steps wired with linear
  # `depends_on` edges and critic `route_to` edges. It composes only phases that
  # are still empty, so it never touches Define (which is composed at creation)
  # and is safe to re-run.
  #
  # Input: the planner's succeeded+merged step_run. Its plan is read from
  # `run.result["artifacts"]["workflow_plan"]` (the worker mirrors declared
  # output artifacts there), so no git access is needed.
  #
  # The project's pipeline_template constrains the result:
  #   * Pinned plan/build/review entries are always materialized (in pinned
  #     order), even if the plan omits them — the plan's extras follow,
  #     duplicates skipped.
  #   * When allow_manager_additions is false, plan entries beyond the pinned
  #     set are ignored (pinned-only materialization).
  #
  # Parallel Build split: the plan's `build` may be either a flat list of step
  # entries (one serial workflow, the common case) OR a list of WORKFLOW entries
  # — `{ "slug", "scope": { "paths": [...] }, "steps": [ ... ] }` — which
  # materialize as SEPARATE workflows that the Manager dispatches in parallel
  # (docs/execution-model.md — "Parallel Builder rule"). A workflow's scope is
  # stamped onto each of its steps so the pre-merge scope check keeps the two
  # implementers off each other's files. The split is honored ONLY when the
  # per-workflow scopes are disjoint and the project neither pins Build steps nor
  # disables additions; otherwise it falls back to a single serial workflow (the
  # steps still run, just in series) and the decision notes why.
  #
  # Idempotent: a phase whose workflow already has steps is left untouched, so a
  # re-merge (or a re-run of this service) never duplicates steps. A malformed
  # plan or a plan naming an unknown template (when additions are allowed)
  # materializes NOTHING and records a ManagerDecision "escalate" on the Plan
  # phase explaining the bad plan.
  class MaterializePlan
    # Ordering of the composed phases (the plan's top-level keys). The Define
    # planner composes all three downstream phases.
    PHASE_KEYS = { "plan" => "plan", "build" => "build", "review" => "review" }.freeze

    # Raised internally to roll the materialization transaction back and fail.
    class Rollback < StandardError; end

    def self.call(step_run:)
      new(step_run:).call
    end

    def initialize(step_run:)
      @step_run = step_run
      @step = step_run.step
      # The phase HOSTING the planner (now Define). Decisions/escalations about a
      # bad plan are recorded here.
      @planner_phase = @step.workflow.phase
      @pipeline = @planner_phase.pipeline
      @project = @pipeline.project
      @pipeline_template = @project.pipeline_template
      @allow_additions = @pipeline_template.nil? || @pipeline_template.allow_manager_additions
      @notes = []
    end

    def call
      plan = parse_plan
      return invalid_plan("Workflow Planner plan is missing or not valid JSON.") if plan.nil?

      templates_by_name = StepTemplate.available_to(@project).index_by(&:name)
      targets = []       # [[phase, workflows], ...] — workflows is [{slug:, scope:, specs:}]
      unknown = []
      ignored = 0

      PHASE_KEYS.each do |key, kind|
        phase = @pipeline.phases.find_by(kind: kind)
        next unless phase && phase_empty?(phase)

        workflows, phase_unknown, phase_ignored =
          workflows_for(kind, plan[key], templates_by_name)
        unknown.concat(phase_unknown)
        ignored += phase_ignored
        targets << [ phase, workflows ] if workflows.any? { |wf| wf[:specs].any? }
      end

      # An unknown template invalidates the whole plan — but only additions can
      # be unknown, so a pinned-only (additions-disabled) materialization never
      # trips this.
      if unknown.any?
        return invalid_plan("Workflow Planner plan names unknown templates: " \
          "#{unknown.uniq.join(", ")}.")
      end

      return Result.success(@step_run) if targets.empty?

      created = []
      ApplicationRecord.transaction do
        targets.each do |phase, workflows|
          workflows.each { |wf| created.concat(materialize_workflow(phase, wf)) }
        end
      end

      return Result.success(@step_run) if created.empty?

      record_success(created, ignored)
      broadcast(created.map { |step| step.workflow.phase }.uniq)
      Result.success(@step_run)
    rescue Rollback
      invalid_plan("Workflow Planner plan could not be materialized " \
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

    # --- workflow planning (single vs. parallel split) ----------------------

    # Returns [workflows, unknown, ignored] for one phase, where a workflow is
    # { slug:, scope:, specs: }. Plan and Review are always a single default
    # workflow. Build is single UNLESS the plan splits it into disjoint,
    # self-contained parallel workflows (see build_workflows).
    def workflows_for(kind, raw, templates_by_name)
      if kind == "build" && split_build?(raw)
        return build_workflows(raw, templates_by_name)
      end

      specs, unknown, ignored = build_specs(kind, plan_entries(raw), templates_by_name)
      [ [ { slug: nil, scope: nil, specs: specs } ], unknown, ignored ]
    end

    # A `build` value is a parallel split when its entries are WORKFLOW objects
    # (they carry a `steps` array) rather than flat step objects.
    def split_build?(raw)
      raw.is_a?(Array) && raw.any? { |entry| entry.is_a?(Hash) && entry["steps"].is_a?(Array) }
    end

    # Turn a split `build` into one workflow per entry — but only when it is safe
    # to run them in parallel. Pinned Build steps or disabled additions mean the
    # project is asserting explicit control over Build, which the split can't
    # honor unambiguously; overlapping scopes would let two implementers stomp
    # each other's files. In either case fall back to a single serial workflow
    # holding every step in order (the work still happens, just not in parallel).
    def build_workflows(raw, templates_by_name)
      entries = raw.select { |entry| entry.is_a?(Hash) && entry["steps"].is_a?(Array) }
      scopes = entries.map { |entry| Array(entry.dig("scope", "paths")) }

      if pinned_templates("build").any? || !@allow_additions
        return serialized_build(entries, templates_by_name,
          "the project pins Build steps or disables additions")
      end
      unless scopes_disjoint?(scopes)
        return serialized_build(entries, templates_by_name,
          "the plan's Build scopes overlap")
      end

      unknown = []
      ignored = 0
      workflows = entries.each_with_index.map do |entry, index|
        specs, entry_unknown, entry_ignored =
          build_specs("build", plan_entries(entry["steps"]), templates_by_name, pinned: false)
        unknown.concat(entry_unknown)
        ignored += entry_ignored
        { slug: workflow_slug(entry, index), scope: entry["scope"], specs: specs }
      end
      [ workflows, unknown, ignored ]
    end

    # Collapse split Build entries back into one serial workflow and note why the
    # requested parallel split was declined.
    def serialized_build(entries, templates_by_name, reason)
      @notes << "Build split not applied (#{reason}); ran the steps serially."
      flat = entries.flat_map { |entry| plan_entries(entry["steps"]) }
      specs, unknown, ignored = build_specs("build", flat, templates_by_name)
      [ [ { slug: nil, scope: nil, specs: specs } ], unknown, ignored ]
    end

    def workflow_slug(entry, index)
      entry["slug"].presence&.parameterize || "build-#{index + 1}"
    end

    # Scopes are disjoint iff no two claim overlapping paths. We compare the
    # literal directory prefix of each glob (everything before the first
    # wildcard): if one prefix is a path-prefix of another they can match the
    # same file. A workflow that declares no paths claims the whole repo, so it
    # overlaps everything — conservative by design (ambiguity ⇒ serial).
    def scopes_disjoint?(scope_lists)
      return false if scope_lists.any?(&:blank?)

      prefixes = scope_lists.map { |paths| paths.map { |path| literal_prefix(path) } }
      prefixes.combination(2).none? do |a, b|
        a.any? { |pa| b.any? { |pb| prefixes_overlap?(pa, pb) } }
      end
    end

    def literal_prefix(pattern)
      string = pattern.to_s
      wildcard = string.index(/[*?\[{]/)
      (wildcard ? string[0...wildcard] : string).chomp("/")
    end

    def prefixes_overlap?(first, second)
      first.empty? || second.empty? || first == second ||
        first.start_with?("#{second}/") || second.start_with?("#{first}/")
    end

    # --- spec building (pinned merge + additions policy) --------------------

    # Returns [specs, unknown_names, ignored_count] for one phase. A spec is
    # { template: StepTemplate, route_to_name: <name or nil> }. Pinned templates
    # come first (in pinned order); plan entries that aren't pinned follow, and
    # are either included (additions allowed) or counted as ignored (disallowed).
    def build_specs(kind, entries, templates_by_name, pinned: true)
      specs = []
      seen = {}

      (pinned ? pinned_templates(kind) : []).each do |step_template|
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

    # Composes one workflow's specs into steps. Split Build entries carry an
    # explicit `slug` (a dedicated parallel workflow) and `scope` (stamped onto
    # every step so the pre-merge scope check confines it); plan/review and serial
    # Build pass slug/scope nil and land in the phase's default workflow. A critic
    # routes to the step created for its explicit route_to name; failing that
    # (e.g. a pinned critic with no plan-supplied target), it falls back to this
    # workflow's first builder — keeping each parallel workflow self-contained.
    def materialize_workflow(phase, wf)
      workflow = nil
      if wf[:slug]
        workflow = phase.workflows.create(slug: wf[:slug])
        raise Rollback unless workflow.persisted?
      end
      created_by_name = {}
      first_builder = nil

      wf[:specs].map do |spec|
        route_to_id = spec[:route_to_name] && created_by_name[spec[:route_to_name]]&.id
        route_to_id ||= first_builder&.id if spec[:template].type_critic?

        attributes = wf[:scope] ? { scope: wf[:scope] } : {}
        result = Steps::AddToWorkflow.call(phase: phase, attributes: attributes,
          template: spec[:template], route_to_step_id: route_to_id, workflow: workflow)
        raise Rollback unless result.success?

        step = result.value
        created_by_name[spec[:template].name] = step
        first_builder ||= step if step.type_builder?
        step
      end
    end

    # --- outcomes -----------------------------------------------------------

    def record_success(created, ignored)
      counts = created.group_by { |step| step.workflow.phase.kind }
        .transform_values(&:size)
      parts = PHASE_KEYS.values.filter_map { |kind| "#{counts[kind]} #{kind}" if counts[kind] }
      rationale = "Workflow Planner materialized #{parts.join(" + ")} step(s)."

      build_workflows = created.select { |step| step.workflow.phase.build_phase? }
        .map(&:workflow).uniq
      if build_workflows.size > 1
        rationale += " Build split into #{build_workflows.size} parallel workflows " \
          "(#{build_workflows.map(&:slug).join(", ")})."
      end
      if ignored.positive?
        rationale += " Ignored #{ignored} manager addition(s) beyond the pinned " \
          "set (additions are disabled for this project)."
      end
      @notes.each { |note| rationale += " #{note}" }

      @planner_phase.manager_decisions.create!(
        decision: "route_to",
        iteration: @step_run.iteration,
        route_to: created.map(&:slug),
        rationale: rationale
      )
    end

    def invalid_plan(reason)
      @planner_phase.manager_decisions.create!(
        decision: "escalate",
        iteration: @step_run.iteration,
        rationale: "#{reason} Nothing was materialized; the Plan phase needs a " \
          "human to fix or re-run the Workflow Planner."
      )
      Result.failure(:invalid_plan, record: @step_run)
    end

    def broadcast(phases)
      phases.each { |phase| Phases::BroadcastColumn.call(phase) }
    end
  end
end
