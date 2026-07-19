require "test_helper"

class PhasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:dev)
    @pipeline = pipelines(:onboarding)
    @define = phases(:onboarding_define)
    @requirements = steps(:requirements_writer)
    @critic = steps(:completeness_critic)
  end

  test "show renders verdicts, decisions, approvals and both gate forms" do
    @define.update!(status: "consensus", gate_mode: "human")
    @critic.step_runs.create!(state: "succeeded", iteration: 1, required_role: "review",
      verdict: { "verdict" => "needs_work",
                 "findings" => [ { "target_artifact" => "business_requirements",
                                   "issue" => "R-4 is not atomic.", "severity" => "major" } ] })
    @define.manager_decisions.create!(decision: "route_to", iteration: 2,
      rationale: "Routing one finding to requirements.", route_to: [ "requirements" ])
    @define.approvals.create!(user: users(:dev), decision: "send_back",
      target_phase: @define, note: "Earlier bounce.")

    get phase_url(@define)

    assert_response :success
    assert_select "form[action=?]", phase_approval_path(@define)
    assert_select "form[action=?]", send_back_phase_path(@define)
    assert_select "textarea[name=context]"
    assert_select "textarea[name=feedback]"
    assert_select "select[name=target_step_id]"
    assert_match "Needs work", @response.body        # verdict badge
    assert_match "R-4 is not atomic.", @response.body # finding
    assert_match "Routing one finding to requirements.", @response.body # decision
    assert_match "Earlier bounce.", @response.body   # approval history
  end

  test "show hides the gate forms when the phase is not at a human gate" do
    @define.update!(status: "running")
    get phase_url(@define)
    assert_response :success
    assert_select "form[action=?]", phase_approval_path(@define), count: 0
    assert_select "form[action=?]", send_back_phase_path(@define), count: 0
  end

  test "send_back re-opens the phase and redirects to the board" do
    @define.update!(status: "consensus")
    @pipeline.update!(status: "awaiting_human")

    post send_back_phase_url(@define),
      params: { feedback: "Redo requirements.", target_step_id: @requirements.id }

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "running", @define.reload.status
    assert @define.approvals.sole.send_back_decision?
    assert_equal 2, @requirements.step_runs.where(state: "ready").maximum(:iteration)
  end

  test "send_back with blank feedback redirects back with an alert" do
    @define.update!(status: "consensus")
    post send_back_phase_url(@define), params: { feedback: "  " }
    assert_redirected_to phase_url(@define)
    assert_equal "consensus", @define.reload.status
  end

  test "cannot view phases of other users' pipelines" do
    get phase_url(foreign_phase)
    assert_response :not_found
  end

  test "cannot send back phases of other users' pipelines" do
    post send_back_phase_url(foreign_phase), params: { feedback: "x" }
    assert_response :not_found
  end

  private

  def foreign_phase
    other_project = Project.create!(name: "Other4", repo_url: "https://github.com/example/other4")
    other = Pipelines::Create.call(project: other_project, title: "X").value
    other.phases.first.tap { |p| p.update!(status: "consensus") }
  end
end
