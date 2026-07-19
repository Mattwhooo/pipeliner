require "test_helper"

module Dashboard
  class RecentActivityTest < ActiveSupport::TestCase
    setup do
      @user = users(:dev)
      @pipeline = pipelines(:onboarding)
      @define = phases(:onboarding_define)
    end

    test "returns an empty array when there has been no activity" do
      assert_equal [], RecentActivity.new(@user).call
    end

    test "surfaces an approval on a non-review phase as a phase approval" do
      @define.approvals.create!(user: @user, decision: "approve")
      events = RecentActivity.new(@user).call
      assert_equal 1, events.size
      assert_equal :approval, events.first.kind
      assert_match(/Define approved/, events.first.description)
    end

    test "surfaces an approval on the review phase as the pipeline finishing" do
      review = phases(:onboarding_review)
      review.approvals.create!(user: @user, decision: "approve")
      events = RecentActivity.new(@user).call
      assert_match(/finished/, events.first.description)
    end

    test "includes consensus and escalate manager decisions but excludes route_to" do
      @define.manager_decisions.create!(decision: "route_to", iteration: 1, rationale: "noise")
      @define.manager_decisions.create!(decision: "consensus", iteration: 2, rationale: "converged")

      events = RecentActivity.new(@user).call
      assert_equal 1, events.size
      assert_equal :manager_decision, events.first.kind
    end

    test "includes rework events" do
      @pipeline.rework_events.create!(from_phase: phases(:onboarding_plan), target_phase: @define,
        reason: "missing context", mode: "automated", raised_by: "agent")
      events = RecentActivity.new(@user).call
      assert_equal :rework, events.first.kind
      assert_match(/sent back/, events.first.description)
    end

    test "includes terminal step_run completions but not in-flight states" do
      run = step_runs(:requirements_ready)
      run.update!(state: "succeeded", finished_at: Time.current)
      events = RecentActivity.new(@user).call
      assert_equal 1, events.size
      assert_equal :step_run, events.first.kind
    end

    test "sorts newest first and caps at LIMIT" do
      (RecentActivity::LIMIT + 3).times do |i|
        @define.approvals.create!(user: @user, decision: "approve", created_at: i.hours.ago)
      end
      events = RecentActivity.new(@user).call
      assert_equal RecentActivity::LIMIT, events.size
      assert_equal events.map(&:occurred_at).sort.reverse, events.map(&:occurred_at)
    end

    test "excludes activity from projects the user is not a member of" do
      other_project = Project.create!(name: "Other", repo_url: "https://github.com/example/other-recent")
      other_pipeline = Pipelines::Create.call(project: other_project, title: "X").value
      other_define = other_pipeline.phases.find_by!(kind: "define")
      # dev has no membership on other_project, so this approval must not surface.
      other_define.approvals.create!(user: users(:dev), decision: "approve")

      events = RecentActivity.new(@user).call
      assert_equal [], events
    end
  end
end
