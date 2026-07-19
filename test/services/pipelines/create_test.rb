require "test_helper"

module Pipelines
  class CreateTest < ActiveSupport::TestCase
    test "creates a pipeline with its four fixed phases in order" do
      result = Pipelines::Create.call(project: projects(:pipeliner), title: "Do a thing")

      assert result.success?
      pipeline = result.value
      assert_equal %w[define plan build review], pipeline.phases.map(&:kind)
      assert_equal [ 1, 2, 3, 4 ], pipeline.phases.map(&:position)
      assert_match(/\Apipeliner\/pl_[a-z0-9]{8}\z/, pipeline.branch)
    end

    test "starts the pipeline into a running Define phase on creation" do
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Go").value

      assert_equal "running", pipeline.status
      assert_equal "define", pipeline.current_phase
      assert_equal "running", pipeline.phases.find_by!(kind: "define").status
      assert_equal %w[pending pending pending],
        pipeline.phases.where.not(kind: "define").order(:position).map(&:status)
    end

    test "the no-templates fallback still starts the pipeline" do
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Bare start").value

      assert_equal "running", pipeline.status
      assert_equal "running", pipeline.phases.find_by!(kind: "define").status
    end

    test "fails with :invalid when title is missing" do
      result = Pipelines::Create.call(project: projects(:pipeliner), title: "")

      assert result.failure?
      assert_equal :invalid, result.error
      assert result.record.errors[:title].any?
    end

    test "creates nothing when the transaction fails" do
      assert_no_difference [ "Pipeline.count", "Phase.count" ] do
        Pipelines::Create.call(project: projects(:pipeliner), title: "")
      end
    end

    test "sets gate modes: human for define/review, auto for plan/build" do
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Gates").value
      modes = pipeline.phases.index_by(&:kind).transform_values(&:gate_mode)

      assert_equal "human", modes["define"]
      assert_equal "auto", modes["plan"]
      assert_equal "auto", modes["build"]
      assert_equal "human", modes["review"]
    end

    test "composes the Define decision tree from the canonical templates" do
      seed_define_tree_templates
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Tree").value

      define = pipeline.phases.find_by!(kind: "define").workflows.first
      assert_equal %w[code-explorer clarifying-questions human-feedback
                      requirements-writer workflow-planner define-review],
        define.steps.order(:position).map(&:slug)

      by = define.steps.index_by(&:slug)
      # Linear depends_on chain — and it deliberately SKIPS the human step, which
      # is reached only via route_to and never blocks the forward path.
      { "code-explorer" => "clarifying-questions",
        "clarifying-questions" => "requirements-writer",
        "requirements-writer" => "workflow-planner",
        "workflow-planner" => "define-review" }.each do |from, to|
        assert define.step_edges.exists?(from_step: by[from], to_step: by[to], kind: "depends_on"),
          "#{from} -> #{to} depends_on edge"
      end
      # Clarifying Questions ⇄ Human Feedback clarification loop.
      assert define.step_edges.exists?(from_step: by["clarifying-questions"],
        to_step: by["human-feedback"], kind: "route_to")
      assert define.step_edges.exists?(from_step: by["human-feedback"],
        to_step: by["clarifying-questions"], kind: "route_to")
      # Human Feedback sits off the depends_on chain entirely.
      assert_equal 0, define.step_edges.where(kind: "depends_on")
        .where("from_step_id = :id OR to_step_id = :id", id: by["human-feedback"].id).count,
        "human step has no depends_on edges"

      # Plan/Build/Review start empty — the Workflow Planner fills them later.
      %w[plan build review].each do |kind|
        assert pipeline.phases.find_by!(kind: kind).workflows.none? { |w| w.steps.exists? },
          "#{kind} is empty at creation"
      end
    end

    test "creates only phases (no steps) when no templates are available" do
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Bare").value

      pipeline.phases.each do |phase|
        assert phase.workflows.none? { |w| w.steps.exists? }, "#{phase.kind} has no steps"
      end
    end

    # --- pipeline_template-driven composition -------------------------------

    test "Define is the fixed tree regardless of pipeline_template; downstream stays empty when additions allowed" do
      seed_define_tree_templates
      # A pipeline_template exists but allows additions, so Plan is materialized
      # later by the Define Workflow Planner, not composed at creation.
      pin_template(allow_additions: true)

      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "FromTemplate").value

      define = pipeline.phases.find_by!(kind: "define").workflows.first
      assert_equal %w[code-explorer clarifying-questions human-feedback
                      requirements-writer workflow-planner define-review],
        define.steps.order(:position).map(&:slug),
        "the Define decision tree ignores pinned define composition"

      %w[plan build review].each do |kind|
        assert pipeline.phases.find_by!(kind: kind).workflows.none? { |w| w.steps.exists? },
          "#{kind} is empty at creation"
      end
    end

    test "composes build/review at creation when the template forbids manager additions" do
      seed_composition_templates
      seed_build_review_templates
      pin_template(allow_additions: false,
        "define" => [ "Requirements Writer" ],
        "plan" => [ "Workflow Composer", "Design Writer" ],
        "build" => [ "Implementer", "Test Critic" ],
        "review" => [ "Requirements Conformance Critic", "Review Report Writer" ])

      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Locked").value

      build = pipeline.phases.find_by!(kind: "build").workflows.first
      assert_equal %w[implementer test-critic], build.steps.order(:position).map(&:slug)
      impl = build.steps.find_by!(slug: "implementer")
      critic = build.steps.find_by!(slug: "test-critic")
      assert build.step_edges.exists?(from_step: critic, to_step: impl, kind: "route_to"),
        "build critic routes to the first builder"

      review = pipeline.phases.find_by!(kind: "review").workflows.first
      assert_equal %w[requirements-conformance-critic review-report-writer],
        review.steps.order(:position).map(&:slug)
    end

    private

    # Pins the given per-phase template-name lists onto the project's
    # pipeline_template (templates must already exist).
    def pin_template(allow_additions: true, **pinned)
      pt = projects(:pipeliner).create_pipeline_template!(allow_manager_additions: allow_additions)
      pinned.each do |phase, names|
        names.each_with_index do |name, index|
          step_template = StepTemplate.available_to(projects(:pipeliner)).find_by!(name: name)
          pt.pipeline_template_steps.create!(step_template: step_template, phase: phase.to_s,
            position: index + 1)
        end
      end
      pt
    end

    # The six canonical Define decision-tree templates (Pipelines::Create wires
    # them by these exact names).
    def seed_define_tree_templates
      StepTemplate.create!(name: "Code Explorer", step_type: "builder", role: "code",
        phase: "define", requirement: "required")
      StepTemplate.create!(name: "Clarifying Questions", step_type: "critic", role: "review",
        phase: "define", requirement: "required")
      StepTemplate.create!(name: "Human Feedback", step_type: "human", role: "human",
        phase: "define", requirement: "required")
      StepTemplate.create!(name: "Requirements Writer", step_type: "builder", role: "requirements",
        phase: "define", requirement: "required")
      StepTemplate.create!(name: "Workflow Planner", step_type: "planner", role: "code",
        phase: "define", requirement: "required")
      StepTemplate.create!(name: "Define Review", step_type: "builder", role: "review",
        phase: "define", requirement: "required")
    end

    def seed_build_review_templates
      StepTemplate.create!(name: "Implementer", step_type: "builder", role: "code",
        phase: "build", requirement: "required")
      StepTemplate.create!(name: "Test Critic", step_type: "critic", role: "code",
        phase: "build", requirement: "required")
      StepTemplate.create!(name: "Requirements Conformance Critic", step_type: "critic",
        role: "review", phase: "review", requirement: "required")
      StepTemplate.create!(name: "Review Report Writer", step_type: "builder", role: "review",
        phase: "review", requirement: "required")
    end

    # Minimal template set so composition is deterministic: the three define
    # core steps, one project-specific "run late" define step, and the plan
    # chain. Plan critics carry an explicit phase so they aren't pulled into
    # Define as custom late steps (for_phase("define") also matches phase: nil).
    def seed_composition_templates
      StepTemplate.create!(name: "Requirements Writer", step_type: "builder",
        role: "requirements", phase: "define", requirement: "required")
      StepTemplate.create!(name: "Clarifying Questions Writer", step_type: "builder",
        role: "requirements", phase: "define", requirement: "conditional")
      StepTemplate.create!(name: "Requirements Completeness Critic", step_type: "critic",
        role: "review", phase: "define", requirement: "required")
      StepTemplate.create!(name: "Threat Model Writer", step_type: "builder",
        role: "security", phase: "define", requirement: "conditional",
        project: projects(:pipeliner))

      StepTemplate.create!(name: "Workflow Composer", step_type: "planner",
        role: "code", phase: "plan", requirement: "required")
      StepTemplate.create!(name: "Design Writer", step_type: "builder",
        role: "code", phase: "plan", requirement: "required")
      StepTemplate.create!(name: "Guide Alignment Critic", step_type: "critic",
        role: "review", phase: "plan", requirement: "conditional")
      StepTemplate.create!(name: "Design Coverage Critic", step_type: "critic",
        role: "review", phase: "plan", requirement: "required")
    end
  end
end
