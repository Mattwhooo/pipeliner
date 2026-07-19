require "test_helper"

class PipelinesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "show renders the define pre-phase panel and the three downstream columns" do
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "h1", pipelines(:onboarding).title
    assert_select "h2", /Definition/       # define is a full-width panel, not a column
    assert_select "h3", /Plan/
    assert_select "h3", /Build/
    assert_select "h3", /Review/
    assert_select "h3", { text: /^Define$/, count: 0 } # no Define column
  end

  test "show renders the define Q&A section when open questions are present" do
    steps(:requirements_writer).step_runs.create!(
      state: "succeeded", iteration: 2, required_role: "requirements",
      result: { "artifacts" => { "open_questions" => "1. Which auth provider?" } }
    )
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_match "Open questions", @response.body
    assert_match "Which auth provider?", @response.body
    assert_select "form[action=?]", answers_phase_path(phases(:onboarding_define))
    assert_select "textarea[name=answers]"
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
