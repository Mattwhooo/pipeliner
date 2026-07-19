require "test_helper"

class PipelinesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "show hides the downstream columns until planning, showing a placeholder" do
    # Onboarding fixtures have steps only in Define — Plan/Build/Review are empty
    # until the Workflow Planner materializes them, so they must not show yet.
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "h1", pipelines(:onboarding).title
    assert_select "h2", /Definition/       # define is a full-width panel, not a column
    assert_match "Phases appear after planning", @response.body
    assert_select "h3", { text: /^Plan$/, count: 0 }
    assert_select "h3", { text: /^Build$/, count: 0 }
    assert_select "h3", { text: /^Define$/, count: 0 } # no Define column
  end

  test "show renders the Human Feedback form with one field per open question" do
    define = phases(:onboarding_define)
    define.update!(status: "running")
    workflow = define.workflows.first
    # Clarifying Questions raised structured questions...
    steps(:completeness_critic).step_runs.create!(state: "succeeded", iteration: 1,
      required_role: "review",
      result: { "artifacts" => { "open_questions_structured" =>
        [ { "question" => "Which auth provider?", "default" => "OAuth" } ] } })
    # ...and the Human Feedback step is awaiting the human's answers.
    human = workflow.steps.create!(slug: "human-feedback", step_type: "human",
      role: "human", position: 9)
    human.step_runs.create!(state: "awaiting_input", iteration: 1, required_role: "human")

    get pipeline_url(pipelines(:onboarding))

    assert_response :success
    assert_select "form[action=?]", submit_feedback_phase_path(define)
    assert_match "Which auth provider?", @response.body
    assert_select "input[name=?]", "answer[]"
    assert_select "textarea[name=notes]"
  end

  test "show renders a downstream column once the Workflow Planner has materialized it" do
    plan = phases(:onboarding_plan)
    plan.workflows.create!(slug: "main").steps.create!(slug: "design-writer",
      step_type: "builder", role: "code", position: 1)

    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "h3", /Plan/
    assert_no_match "Phases appear after planning", @response.body
  end

  test "show renders the define open questions read-only, pointing to the dashboard to answer" do
    steps(:requirements_writer).step_runs.create!(
      state: "succeeded", iteration: 2, required_role: "requirements",
      result: { "artifacts" => { "open_questions" => "1. Which auth provider?" } }
    )
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_match "Open questions", @response.body
    assert_match "Which auth provider?", @response.body
    assert_match "Answer these from the dashboard.", @response.body
    # The inline free-text answer form was removed (Q14) in favor of the
    # dashboard's per-question modal.
    assert_select "form[action=?]", answers_phase_path(phases(:onboarding_define)), count: 0
    assert_select "textarea[name=answers]", count: 0
  end

  test "show hides the Q&A section when there are no open questions" do
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "textarea[name=answers]", count: 0
  end

  test "show renders the amber gate and approve form when define is at consensus" do
    phases(:onboarding_define).update!(status: "consensus", gate_mode: "human")
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "form[action=?]", phase_approval_path(phases(:onboarding_define))
    assert_match "Consensus reached", @response.body
  end

  test "show collapses the define panel to a summary strip once approved" do
    phases(:onboarding_define).update!(status: "approved")
    phases(:onboarding_define).approvals.create!(user: users(:dev), decision: "approve")
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_match "Defined", @response.body
    assert_select "textarea[name=answers]", count: 0
    assert_select "form[action=?]", phase_approval_path(phases(:onboarding_define)), count: 0
  end

  test "show renders the live board: stream tag and step cards" do
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "turbo-cable-stream-source", 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(steps(:requirements_writer), :card)}" do
      assert_select "span", /Requirements/
    end
    assert_select "##{ActionView::RecordIdentifier.dom_id(steps(:completeness_critic), :card)}"
  end

  test "create builds the pipeline and redirects to it" do
    post project_pipelines_url(projects(:pipeliner)), params: { pipeline: {
      title: "New work", initial_prompt: "Do the thing."
    } }
    pipeline = Pipeline.find_by!(title: "New work")
    assert_redirected_to pipeline_url(pipeline)
    assert_equal 4, pipeline.phases.count
  end

  test "invalid create re-renders the form" do
    post project_pipelines_url(projects(:pipeliner)), params: { pipeline: { title: "" } }
    assert_response :unprocessable_entity
  end
end
