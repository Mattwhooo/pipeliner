require "test_helper"

# End-to-end worker lifecycle over the HTTP API:
# register → claim → heartbeat → progress → complete.
class WorkerApiLifecycleTest < ActionDispatch::IntegrationTest
  REGISTRATION_HEADERS = { "X-Registration-Key" => "dev-registration-key" }.freeze

  test "full worker lifecycle" do
    # Register
    post api_v1_workers_register_url, headers: REGISTRATION_HEADERS, params: {
      worker: { public_id: "wk_e2e", name: "E2E worker", backend: "claude-code",
                roles: [ "requirements" ], concurrency: 1 }
    }, as: :json
    assert_response :created
    token = response.parsed_body["token"]
    auth = { "Authorization" => "Bearer #{token}" }

    # Claim → context bundle
    post api_v1_claims_url, headers: auth, as: :json
    assert_response :ok
    bundle = response.parsed_body
    run_id = bundle.dig("step_run", "id")
    epoch = bundle.dig("step_run", "epoch")
    assert_equal "requirements", bundle.dig("step", "role")
    assert_equal "pipeliner/pl_onboarding", bundle.dig("pipeline", "branch")

    # Second claim with concurrency 1 → no content (at capacity)
    post api_v1_claims_url, headers: auth, as: :json
    assert_response :no_content

    # Heartbeat renews the lease, no cancel
    post heartbeat_api_v1_step_run_url(run_id), headers: auth,
      params: { epoch: epoch, roles: [ "requirements" ] }, as: :json
    assert_response :ok
    assert_equal false, response.parsed_body["cancel"]

    # Progress moves it to running
    post progress_api_v1_step_run_url(run_id), headers: auth,
      params: { epoch: epoch, progress: { message: "drafting requirements" } }, as: :json
    assert_response :ok
    assert_equal "running", StepRun.find(run_id).state

    # Complete
    post complete_api_v1_step_run_url(run_id), headers: auth,
      params: { epoch: epoch, status: "succeeded", commit_sha: "abc1234",
                result: { outputs: [ "requirements.md" ] } }, as: :json
    assert_response :ok
    run = StepRun.find(run_id)
    assert_equal "succeeded", run.state
    assert_equal "abc1234", run.commit_sha
  end

  test "stale epoch heartbeat tells the worker to cancel" do
    post api_v1_workers_register_url, headers: REGISTRATION_HEADERS, params: {
      worker: { public_id: "wk_stale", roles: [ "requirements" ] }
    }, as: :json
    auth = { "Authorization" => "Bearer #{response.parsed_body['token']}" }

    post api_v1_claims_url, headers: auth, as: :json
    run_id = response.parsed_body.dig("step_run", "id")

    post heartbeat_api_v1_step_run_url(run_id), headers: auth,
      params: { epoch: "not-the-real-epoch" }, as: :json
    assert_response :ok
    assert_equal true, response.parsed_body["cancel"]
  end

  test "requests without a valid worker token are unauthorized" do
    post api_v1_claims_url, headers: { "Authorization" => "Bearer nope" }, as: :json
    assert_response :unauthorized
  end

  test "registration requires the registration key" do
    post api_v1_workers_register_url, params: { worker: { public_id: "wk_x" } }, as: :json
    assert_response :unauthorized
  end
end
