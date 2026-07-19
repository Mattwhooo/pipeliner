require "test_helper"

module Workflows
  class MaterializePlanTest < ActiveSupport::TestCase
    setup do
      @project = projects(:pipeliner)
      @pipeline = pipelines(:onboarding)
      @plan_phase = phases(:onboarding_plan)
      @build_phase = phases(:onboarding_build)
      @review_phase = phases(:onboarding_review)

      StepTemplate.create!(name: "Implementer", step_type: "builder", role: "code",
        phase: "build", requirement: "required",
        default_outputs: [ { "artifact" => "implementation", "kind" => "repo" } ])
      StepTemplate.create!(name: "Test Critic", step_type: "critic", role: "code",
        phase: "build", requirement: "required")
      StepTemplate.create!(name: "Requirements Conformance Critic", step_type: "critic",
        role: "review", phase: "review", requirement: "required")

      @composer = @plan_phase.workflows.create!(slug: "main").steps.create!(
        slug: "workflow-composer", step_type: "planner", role: "code", position: 1)
    end

    test "a valid plan composes build+review steps with depends_on and route_to edges" do
      run = composer_run(
        "build" => [
          { "template" => "Implementer", "route_to" => nil },
          { "template" => "Test Critic", "route_to" => "Implementer" }
        ],
        "review" => [ { "template" => "Requirements Conformance Critic", "route_to" => nil } ]
      )

      result = MaterializePlan.call(step_run: run)

      assert result.success?
      build_wf = @build_phase.workflows.first
      assert_equal %w[implementer test-critic], build_wf.steps.order(:position).map(&:slug)
      impl = build_wf.steps.find_by!(slug: "implementer")
      critic = build_wf.steps.find_by!(slug: "test-critic")
      assert build_wf.step_edges.exists?(from_step: impl, to_step: critic, kind: "depends_on")
      assert build_wf.step_edges.exists?(from_step: critic, to_step: impl, kind: "route_to")

      review_wf = @review_phase.workflows.first
      assert_equal %w[requirements-conformance-critic], review_wf.steps.map(&:slug)

      decision = @plan_phase.manager_decisions.order(:created_at).last
      assert_equal "route_to", decision.decision
      assert_match(/materialized 2 build \+ 1 review/, decision.rationale)
    end

    test "is idempotent — a second call creates no duplicate steps" do
      run = composer_run(
        "build" => [ { "template" => "Implementer" } ],
        "review" => [ { "template" => "Requirements Conformance Critic" } ]
      )
      assert MaterializePlan.call(step_run: run).success?
      assert_equal 1, @build_phase.workflows.first.steps.count
      assert_equal 1, @review_phase.workflows.first.steps.count

      assert_no_difference "Step.count" do
        assert MaterializePlan.call(step_run: run).success?
      end
    end

    test "an unknown template fails with :invalid_plan and materializes nothing" do
      run = composer_run(
        "build" => [ { "template" => "Implementer" }, { "template" => "No Such Step" } ],
        "review" => []
      )

      assert_no_difference "Step.count" do
        result = MaterializePlan.call(step_run: run)
        assert result.failure?
        assert_equal :invalid_plan, result.error
      end
      assert @build_phase.workflows.none? { |w| w.steps.exists? }
      decision = @plan_phase.manager_decisions.order(:created_at).last
      assert_equal "escalate", decision.decision
      assert_match(/No Such Step/, decision.rationale)
    end

    test "a missing workflow_plan artifact fails with :invalid_plan" do
      run = @composer.step_runs.create!(state: "succeeded", iteration: 1,
        required_role: "code", merged_at: Time.current, result: {})

      result = MaterializePlan.call(step_run: run)

      assert result.failure?
      assert_equal :invalid_plan, result.error
      assert_equal "escalate", @plan_phase.manager_decisions.order(:created_at).last.decision
    end

    test "invalid JSON in the artifact fails with :invalid_plan" do
      run = @composer.step_runs.create!(state: "succeeded", iteration: 1,
        required_role: "code", merged_at: Time.current,
        result: { "artifacts" => { "workflow_plan" => "{not json" } })

      result = MaterializePlan.call(step_run: run)

      assert result.failure?
      assert_equal :invalid_plan, result.error
    end

    # --- pipeline_template constraints --------------------------------------

    test "pinned build/review entries are materialized even when the plan omits them" do
      pin_template(allow_additions: true,
        "build" => [ "Implementer" ],
        "review" => [ "Requirements Conformance Critic" ])
      run = composer_run(
        "build" => [ { "template" => "Test Critic", "route_to" => "Implementer" } ],
        "review" => []
      )

      assert MaterializePlan.call(step_run: run).success?

      # Pinned Implementer first (though the plan omitted it), then the plan's
      # Test Critic addition.
      assert_equal %w[implementer test-critic],
        @build_phase.workflows.first.steps.order(:position).map(&:slug)
      impl = @build_phase.workflows.first.steps.find_by!(slug: "implementer")
      critic = @build_phase.workflows.first.steps.find_by!(slug: "test-critic")
      assert @build_phase.workflows.first.step_edges.exists?(
        from_step: critic, to_step: impl, kind: "route_to")

      assert_equal %w[requirements-conformance-critic],
        @review_phase.workflows.first.steps.map(&:slug)
    end

    test "additions disallowed materializes only pinned steps and notes the ignored count" do
      pin_template(allow_additions: false, "build" => [ "Implementer", "Test Critic" ])
      run = composer_run(
        # Two extras beyond the pinned set (one of them not even a real template)
        # plus a review addition — all must be ignored, none may invalidate.
        "build" => [ { "template" => "Implementer" }, { "template" => "Test Critic", "route_to" => "Implementer" },
                     { "template" => "No Such Critic" } ],
        "review" => [ { "template" => "Requirements Conformance Critic" } ]
      )

      result = MaterializePlan.call(step_run: run)

      assert result.success?
      assert_equal %w[implementer test-critic],
        @build_phase.workflows.first.steps.order(:position).map(&:slug)
      assert @review_phase.workflows.none? { |w| w.steps.exists? },
        "no review steps: review has no pinned entries and additions are disabled"

      decision = @plan_phase.manager_decisions.order(:created_at).last
      assert_equal "route_to", decision.decision
      assert_match(/Ignored 2 manager addition/, decision.rationale)
    end

    test "a plan addition duplicating a pinned entry is not materialized twice" do
      pin_template(allow_additions: true, "build" => [ "Implementer" ])
      run = composer_run(
        "build" => [ { "template" => "Implementer" } ],
        "review" => []
      )

      assert MaterializePlan.call(step_run: run).success?
      assert_equal %w[implementer], @build_phase.workflows.first.steps.map(&:slug)
    end

    test "a Define-hosted planner also composes the Plan phase" do
      # In the real flow the planner lives in Define and Plan starts empty; the
      # shared setup parks a composer in Plan, so clear it here.
      @plan_phase.workflows.destroy_all
      StepTemplate.create!(name: "Design Writer", step_type: "builder", role: "code",
        phase: "plan", requirement: "required")
      define = phases(:onboarding_define)
      planner = define.workflows.create!(slug: "planner-wf").steps.create!(
        slug: "workflow-planner", step_type: "planner", role: "code", position: 1)
      run = planner.step_runs.create!(state: "succeeded", iteration: 1, required_role: "code",
        merged_at: Time.current, result: { "artifacts" => { "workflow_plan" => {
          "plan" => [ { "template" => "Design Writer" } ],
          "build" => [ { "template" => "Implementer" } ],
          "review" => [ { "template" => "Requirements Conformance Critic" } ]
        }.to_json } })

      result = MaterializePlan.call(step_run: run)

      assert result.success?
      assert_equal %w[design-writer], @plan_phase.workflows.reload.first.steps.map(&:slug)
      assert_equal %w[implementer], @build_phase.workflows.reload.first.steps.map(&:slug)
      assert_equal %w[requirements-conformance-critic], @review_phase.workflows.reload.first.steps.map(&:slug)
      # The decision is recorded on the phase that HOSTS the planner (Define).
      decision = define.manager_decisions.order(:created_at).last
      assert_match(/1 plan \+ 1 build \+ 1 review/, decision.rationale)
    end

    private

    def composer_run(plan)
      @composer.step_runs.create!(state: "succeeded", iteration: 1,
        required_role: "code", merged_at: Time.current,
        result: { "artifacts" => { "workflow_plan" => plan.to_json } })
    end

    def pin_template(allow_additions: true, **pinned)
      pt = @project.create_pipeline_template!(allow_manager_additions: allow_additions)
      pinned.each do |phase, names|
        names.each_with_index do |name, index|
          step_template = StepTemplate.available_to(@project).find_by!(name: name)
          pt.pipeline_template_steps.create!(step_template: step_template, phase: phase.to_s,
            position: index + 1)
        end
      end
      pt
    end
  end
end
