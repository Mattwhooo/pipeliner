require "test_helper"

class ApprovalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:dev)
    @define = phases(:onboarding_define)
  end

  test "approving a consensus phase advances the pipeline" do
    @define.update!(status: "consensus")
    pipelines(:onboarding).update!(status: "awaiting_human")

    post phase_approval_url(@define), params: { note: "ship it" }

    assert_redirected_to pipeline_url(pipelines(:onboarding))
    assert_equal "approved", @define.reload.status
    assert_equal "plan", pipelines(:onboarding).reload.current_phase
    assert_equal "ship it", @define.approvals.sole.note
  end

  test "approving a phase not at a gate redirects with an alert" do
    @define.update!(status: "running")
    post phase_approval_url(@define)
    assert_redirected_to pipeline_url(pipelines(:onboarding))
    assert_equal "running", @define.reload.status
  end

  test "board shows the gate banner when a human gate is pending" do
    @define.update!(status: "consensus", gate_mode: "human")
    get pipeline_url(pipelines(:onboarding))
    assert_select "form[action=?]", phase_approval_path(@define)
    assert_select "input[type=submit][value=?]", "Approve Define"
  end

  test "cannot approve phases of other users' pipelines" do
    other_project = Project.create!(name: "Other3", repo_url: "https://github.com/example/other3")
    other = Pipelines::Create.call(project: other_project, title: "X").value
    other.phases.first.update!(status: "consensus")
    post phase_approval_url(other.phases.first)
    assert_response :not_found
  end
end
