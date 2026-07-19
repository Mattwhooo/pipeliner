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

    test "auto-composes the Define core and Plan chain from available templates" do
      seed_composition_templates
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Compose").value

      define = pipeline.phases.find_by!(kind: "define").workflows.first
      assert_equal %w[requirements-writer clarifying-questions-writer threat-model-writer
                      requirements-completeness-critic],
        define.steps.order(:position).map(&:slug)
      writer = define.steps.find_by!(slug: "requirements-writer")
      critic = define.steps.find_by!(slug: "requirements-completeness-critic")
      assert define.step_edges.exists?(from_step: critic, to_step: writer, kind: "route_to"),
        "completeness critic routes back to the requirements writer"

      plan = pipeline.phases.find_by!(kind: "plan").workflows.first
      assert_equal %w[workflow-composer design-writer guide-alignment-critic design-coverage-critic],
        plan.steps.order(:position).map(&:slug)
      designer = plan.steps.find_by!(slug: "design-writer")
      assert_equal 2,
        plan.step_edges.where(to_step: designer, kind: "route_to").count,
        "both plan critics route back to the design writer"
    end

    test "leaves Build and Review empty for the composer to fill" do
      seed_composition_templates
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Compose").value

      assert pipeline.phases.find_by!(kind: "build").workflows.none? { |w| w.steps.exists? }
      assert pipeline.phases.find_by!(kind: "review").workflows.none? { |w| w.steps.exists? }
    end

    test "creates only phases (no steps) when no templates are available" do
      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Bare").value

      pipeline.phases.each do |phase|
        assert phase.workflows.none? { |w| w.steps.exists? }, "#{phase.kind} has no steps"
      end
    end

    # --- pipeline_template-driven composition -------------------------------

    test "composes Define and Plan from the pipeline_template, leaving build/review empty" do
      seed_composition_templates
      pin_template(allow_additions: true,
        "define" => [ "Requirements Writer", "Clarifying Questions Writer",
                      "Requirements Completeness Critic" ],
        "plan" => [ "Workflow Composer", "Design Writer",
                    "Guide Alignment Critic", "Design Coverage Critic" ])

      pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "FromTemplate").value

      define = pipeline.phases.find_by!(kind: "define").workflows.first
      assert_equal %w[requirements-writer clarifying-questions-writer threat-model-writer
                      requirements-completeness-critic],
        define.steps.order(:position).map(&:slug),
        "pinned define order with the custom late step inserted before the trailing critic"
      writer = define.steps.find_by!(slug: "requirements-writer")
      critic = define.steps.find_by!(slug: "requirements-completeness-critic")
      assert define.step_edges.exists?(from_step: critic, to_step: writer, kind: "route_to"),
        "define critic routes to the first builder"

      plan = pipeline.phases.find_by!(kind: "plan").workflows.first
      assert_equal %w[workflow-composer design-writer guide-alignment-critic design-coverage-critic],
        plan.steps.order(:position).map(&:slug)

      assert pipeline.phases.find_by!(kind: "build").workflows.none? { |w| w.steps.exists? }
      assert pipeline.phases.find_by!(kind: "review").workflows.none? { |w| w.steps.exists? }
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
