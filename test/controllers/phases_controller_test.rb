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

  test "answers queues a new requirements run and re-opens a consensus define" do
    @define.update!(status: "consensus")
    @pipeline.update!(status: "awaiting_human")
    step_runs(:requirements_ready).update!(state: "succeeded")

    post answers_phase_url(@define), params: { answers: "1. Use OAuth." }

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "running", @define.reload.status
    assert_equal "running", @pipeline.reload.status
    run = @requirements.step_runs.where(state: "ready").order(:iteration).last
    assert_equal 2, run.iteration
    assert_equal "1. Use OAuth.", run.feedback.first["issue"]
    assert_equal "human", run.feedback.first["from"]
  end

  test "answers as turbo_stream returns 200 with no body on success" do
    @define.update!(status: "consensus")
    @pipeline.update!(status: "awaiting_human")
    step_runs(:requirements_ready).update!(state: "succeeded")

    post answers_phase_url(@define), params: { answers: "1. Use OAuth." },
      as: :turbo_stream

    assert_response :success
    assert_equal "running", @define.reload.status
  end

  test "answers as turbo_stream returns 422 and replaces the error partial on :busy" do
    @define.update!(status: "consensus")
    # requirements_ready fixture is in state ready → the loop is busy.
    post answers_phase_url(@define), params: { answers: "answers" }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match "turbo-stream", @response.media_type
    assert_match "Define is still running", @response.body
    assert_equal "consensus", @define.reload.status
  end

  test "answers as turbo_stream returns 422 on blank answers, preserving the phase state" do
    @define.update!(status: "running")
    step_runs(:requirements_ready).update!(state: "succeeded")

    post answers_phase_url(@define), params: { answers: "   " }, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_match "Add your answers", @response.body
  end

  test "answers is rejected while a define run is in flight" do
    @define.update!(status: "consensus")
    # requirements_ready fixture is in state ready → the loop is busy.
    post answers_phase_url(@define), params: { answers: "answers" }

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "consensus", @define.reload.status
    assert_equal 1, @requirements.step_runs.count
  end

  test "answers with blank text is rejected" do
    @define.update!(status: "running")
    step_runs(:requirements_ready).update!(state: "succeeded")

    post answers_phase_url(@define), params: { answers: "   " }

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal 1, @requirements.step_runs.count
  end

  test "pause flags a pause request while a step is in flight" do
    @define.update!(status: "running")
    # requirements_ready fixture is in state ready → the loop is busy.
    post pause_phase_url(@define)

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "running", @define.reload.status
    assert @define.pause_requested?
  end

  test "pause takes effect immediately when nothing is in flight" do
    @define.update!(status: "running")
    step_runs(:requirements_ready).update!(state: "succeeded")

    post pause_phase_url(@define)

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "paused", @define.reload.status
  end

  test "pause is rejected outside running" do
    @define.update!(status: "consensus")
    post pause_phase_url(@define)
    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "consensus", @define.reload.status
  end

  test "rerun_step queues a fresh run for the requested artifact" do
    @requirements.update!(outputs: [ { "artifact" => "business_requirements", "kind" => "artifact",
                                        "path" => "output/requirements.md" } ])
    explorer = workflows(:define_main).steps.create!(slug: "explore", step_type: "builder",
      role: "code", position: 0,
      outputs: [ { "artifact" => "discovery_notes", "kind" => "artifact",
                   "path" => "output/discovery_notes.md" } ])
    step_runs(:requirements_ready).update!(state: "succeeded")
    @define.update!(status: "paused")

    post rerun_step_phase_url(@define), params: { artifact: "discovery_notes" }

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "paused", @define.reload.status
    assert_equal 1, explorer.step_runs.where(state: "ready").count
  end

  test "rerun_step is rejected while the phase is busy" do
    @define.update!(status: "paused")
    # requirements_ready fixture is in state ready → the loop is busy.
    post rerun_step_phase_url(@define), params: { artifact: "open_questions" }

    assert_redirected_to pipeline_url(@pipeline)
  end

  test "restart queues a fresh run on the first worker step and flips to running" do
    step_runs(:requirements_ready).update!(state: "succeeded")
    @define.update!(status: "paused")

    post restart_phase_url(@define)

    assert_redirected_to pipeline_url(@pipeline)
    @define.reload
    assert @define.running?
    assert @define.restart_in_progress?
  end

  test "restart is rejected when the phase isn't paused" do
    @define.update!(status: "running")
    post restart_phase_url(@define)
    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "running", @define.reload.status
    assert_not @define.restart_in_progress?
  end

  test "cannot pause phases of other users' pipelines" do
    post pause_phase_url(foreign_phase)
    assert_response :not_found
  end

  test "cannot answer questions on other users' pipelines" do
    post answers_phase_url(foreign_phase), params: { answers: "x" }
    assert_response :not_found
  end

  test "submit_feedback completes the pending human step and redirects to the board" do
    @define.update!(status: "running")
    human = @define.workflows.first.steps.create!(slug: "human-feedback", step_type: "human",
      role: "human", position: 3,
      outputs: [ { "artifact" => "human_answers", "kind" => "artifact", "path" => "output/human_answers.md" } ])
    run = human.step_runs.create!(state: "awaiting_input", iteration: 1, required_role: "human")

    post submit_feedback_phase_url(@define),
      params: { question: [ "Scope?" ], answer: [ "just the API" ], notes: "small" }

    assert_redirected_to pipeline_url(@pipeline)
    assert_equal "succeeded", run.reload.state
    assert_equal "just the API", run.result.dig("artifacts", "human_answers_structured").first["answer"]
  end

  test "submit_feedback redirects with an alert when there is nothing to answer" do
    @define.update!(status: "running")
    post submit_feedback_phase_url(@define),
      params: { question: [ "Q?" ], answer: [ "A" ], notes: "" }

    assert_redirected_to pipeline_url(@pipeline)
    assert_match "no open questions", flash[:alert]
  end

  test "cannot submit feedback on other users' pipelines" do
    post submit_feedback_phase_url(foreign_phase), params: { notes: "x" }
    assert_response :not_found
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
