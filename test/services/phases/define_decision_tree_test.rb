require "test_helper"

module Phases
  # End-to-end coverage of the Define decision tree (docs/execution-model.md —
  # "Define decision tree"): Code Explorer → Clarifying Questions ⇄ Human
  # Feedback → Requirements Writer → Workflow Planner → Define Review, driven by
  # ManagerTick with the human answering via Phases::SubmitHumanFeedback.
  class DefineDecisionTreeTest < ActiveSupport::TestCase
    setup do
      seed_define_templates
      @user = users(:dev)
      @pipeline = Pipelines::Create.call(project: projects(:pipeliner), title: "Tree").value
      @define = @pipeline.phases.find_by!(kind: "define")
    end

    test "runs the full loop: clarify, get human feedback, then flow forward to a human gate" do
      # 1. Only Code Explorer is dispatched first.
      tick
      assert_ready explorer
      assert_nil clarifying.latest_run, "clarifying waits for the explorer"

      # 2. Explorer merges → Clarifying Questions dispatched; nothing downstream.
      finish(explorer)
      tick
      assert_ready clarifying
      assert_nil requirements.latest_run, "requirements waits for clarifying to PASS"

      # 3. Clarifying needs_work → Human Feedback dispatched (awaiting_input),
      #    the forward chain still blocked, and the explorer NOT re-run.
      finish(clarifying, verdict: needs_work, artifacts: {
        "open_questions_structured" => [ { "question" => "Scope?", "default" => "all" } ]
      })
      tick
      hf_run = human_feedback.latest_run
      assert_equal "awaiting_input", hf_run.state
      assert_equal 1, explorer.step_runs.count, "explorer runs once for the pipeline"
      assert_nil requirements.latest_run

      # A human-role worker cannot claim the awaiting_input run.
      worker = Worker.create!(public_id: "wk_h", name: "H", status: "online",
        supported_roles: [ "human" ], concurrency: 1, last_heartbeat_at: Time.current,
        auth_token_digest: "x")
      assert_empty StepRuns::ClaimableFor.new(worker).relation.to_a

      # 4. Human submits → Clarifying re-runs at iteration 2 with the answers,
      #    explorer still untouched.
      Phases::SubmitHumanFeedback.call(phase: @define, user: @user,
        answers: [ { question: "Scope?", answer: "just the API" } ], notes: "keep it small")
      tick
      cq2 = clarifying.reload.latest_run
      assert_equal 2, cq2.iteration
      assert_equal "ready", cq2.state
      assert cq2.feedback.any? { |f| f["from"] == "human" && f["issue"].include?("just the API") }
      assert_equal 1, explorer.step_runs.count

      # 5. Clarifying PASSES → the forward chain unblocks one step at a time.
      finish(clarifying, verdict: pass)
      tick
      assert_ready requirements
      finish(requirements)
      tick
      assert_ready planner
      finish(planner)
      tick
      assert_ready define_review, "Define Review runs last, after the planner"

      # 6. Define Review merges → consensus at the human gate.
      finish(define_review)
      tick
      assert_equal "consensus", @define.reload.status
      assert @pipeline.reload.awaiting_human?
    end

    # Non-regression for input fingerprinting: Clarifying Questions consumes the
    # human's answers as feedback, which grows every round, so its fingerprint
    # changes each time and it must RE-RUN for real — never be reused/skipped —
    # even though its declared inputs and its explorer predecessor are unchanged.
    test "Clarifying Questions re-runs on every human answer and is never skipped" do
      tick
      finish(explorer)
      tick

      # Round 1: needs_work -> human answers -> Clarifying re-runs at iteration 2.
      finish(clarifying, verdict: needs_work, artifacts: {
        "open_questions_structured" => [ { "question" => "Scope?", "default" => "all" } ]
      })
      tick
      Phases::SubmitHumanFeedback.call(phase: @define, user: @user,
        answers: [ { question: "Scope?", answer: "just the API" } ])
      tick
      cq2 = clarifying.reload.latest_run
      assert_equal 2, cq2.iteration
      assert_equal "ready", cq2.state

      # Round 2: still needs_work -> a second answer -> Clarifying re-runs at 3.
      finish(clarifying, verdict: needs_work, artifacts: {
        "open_questions_structured" => [ { "question" => "Auth?", "default" => "none" } ]
      })
      tick
      Phases::SubmitHumanFeedback.call(phase: @define, user: @user,
        answers: [ { question: "Auth?", answer: "OAuth" } ])
      tick

      cq3 = clarifying.reload.latest_run
      assert_equal 3, cq3.iteration
      assert_equal "ready", cq3.state, "re-runs for real on the new answer, not reused"
      assert cq3.feedback.any? { |f| f["issue"].to_s.include?("OAuth") }
      assert_not @define.manager_decisions.skip_decision.exists?, "no step was skipped"
      assert_equal 1, explorer.step_runs.count, "the explorer still runs exactly once"
    end

    test "does not advance past Clarifying Questions while it still needs_work" do
      tick
      finish(explorer)
      tick
      finish(clarifying, verdict: needs_work, artifacts: {
        "open_questions_structured" => [ { "question" => "Q?", "default" => "d" } ]
      })
      3.times { tick } # human never answers

      assert_equal "awaiting_input", human_feedback.latest_run.state
      assert_nil requirements.latest_run
      assert_nil planner.latest_run
      assert_nil define_review.latest_run
    end

    private

    def tick = ManagerTick.call(phase: @define.reload)

    def step(slug) = @define.workflows.first.steps.find_by!(slug: slug)
    def explorer = step("code-explorer")
    def clarifying = step("clarifying-questions")
    def human_feedback = step("human-feedback")
    def requirements = step("requirements-writer")
    def planner = step("workflow-planner")
    def define_review = step("define-review")

    def needs_work = { "verdict" => "needs_work", "findings" => [] }
    def pass = { "verdict" => "pass", "findings" => [] }

    def assert_ready(step, msg = nil)
      run = step.latest_run
      assert run, msg || "#{step.slug} has a run"
      assert_equal "ready", run.state, msg || "#{step.slug} is ready"
    end

    # Mark a worker step's current ready run succeeded + merged (what a worker
    # completion plus the branch merge would do).
    def finish(step, verdict: nil, artifacts: {})
      run = step.latest_run
      run.update!(state: "succeeded", verdict: verdict, finished_at: Time.current,
        merged_at: Time.current, result: { "artifacts" => artifacts })
      run
    end

    def seed_define_templates
      [
        [ "Code Explorer", "builder", "code",
          [ art("discovery_notes") ] ],
        [ "Clarifying Questions", "critic", "review",
          [ art("open_questions"), art("open_questions_structured", "output/open_questions.json") ] ],
        [ "Human Feedback", "human", "human", [ art("human_answers") ] ],
        [ "Requirements Writer", "builder", "requirements", [ art("business_requirements") ] ],
        [ "Workflow Planner", "planner", "code", [ art("workflow_plan", "output/workflow_plan.json") ] ],
        [ "Define Review", "builder", "review", [ art("define_summary") ] ]
      ].each do |name, type, role, outputs|
        StepTemplate.create!(name: name, step_type: type, role: role, phase: "define",
          requirement: "required", default_outputs: outputs)
      end
    end

    def art(name, path = "output/#{name}.md")
      { "artifact" => name, "kind" => "artifact", "path" => path }
    end
  end
end
