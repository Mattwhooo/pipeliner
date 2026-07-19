require "test_helper"

module Dashboard
  class ActivePipelinesTest < ActiveSupport::TestCase
    setup do
      @user = users(:dev)
      @pipeline = pipelines(:onboarding)
      @pipeline.update!(status: "running")
    end

    test "only includes pipelines in an active status" do
      @pipeline.update!(status: "completed")
      data = ActivePipelines.new(@user).call
      assert_equal 0, data.total_count
      assert_equal [], data.rows
    end

    test "excludes pipelines the user is not a member of" do
      other = build_other_pipeline(status: "running")
      data = ActivePipelines.new(@user).call
      assert_equal [ @pipeline ], data.rows.map(&:pipeline)
      assert_not_includes data.rows.map(&:pipeline), other
    end

    test "flags awaiting_human and stuck pipelines with distinct reasons" do
      @pipeline.update!(status: "awaiting_human")
      data = ActivePipelines.new(@user).call
      row = data.rows.first
      assert row.attention
      assert_equal :awaiting_human, row.attention_reason

      @pipeline.update!(status: "stuck")
      data = ActivePipelines.new(@user).call
      row = data.rows.first
      assert_equal :stuck, row.attention_reason
    end

    test "derives attention from a stuck step_run in the current phase even when pipeline.status is running" do
      step_runs(:requirements_ready).update!(state: "stuck")
      data = ActivePipelines.new(@user).call
      row = data.rows.first
      assert row.attention
      assert_equal :stuck, row.attention_reason
    end

    test "sorts attention-needing pipelines first, then most-recently-active" do
      @pipeline.update!(status: "running", updated_at: 1.day.ago)
      other = build_other_pipeline(status: "awaiting_human", member: @user)

      data = ActivePipelines.new(@user).call
      assert_equal [ other, @pipeline ], data.rows.map(&:pipeline)
    end

    test "caps rows at the LIMIT while total_count reflects everything" do
      (ActivePipelines::LIMIT + 2).times { |i| build_other_pipeline(status: "running", member: @user, title: "Extra #{i}") }

      data = ActivePipelines.new(@user).call
      assert_equal ActivePipelines::LIMIT, data.rows.size
      assert_equal ActivePipelines::LIMIT + 3, data.total_count
    end

    test "attention_count never exceeds total_count and rows never exceed total_count" do
      data = ActivePipelines.new(@user).call
      assert_operator data.attention_count, :<=, data.total_count
      assert_operator data.rows.size, :<=, data.total_count
    end

    test "empty input returns a zeroed Data struct, not an exception" do
      @pipeline.update!(status: "draft")
      data = ActivePipelines.new(@user).call
      assert_equal ActivePipelines::Data.new(rows: [], total_count: 0, attention_count: 0), data
    end

    test "row_for returns nil once the pipeline drops out of the active scope" do
      query = ActivePipelines.new(@user)
      assert_not_nil query.row_for(@pipeline)

      @pipeline.update!(status: "completed")
      assert_nil query.row_for(@pipeline)
    end

    private

    def build_other_pipeline(status:, member: nil, title: "Other pipeline")
      project = Project.create!(name: "Other #{SecureRandom.hex(4)}", repo_url: "https://github.com/example/other-#{SecureRandom.hex(4)}")
      project.memberships.create!(user: member, role: "member") if member
      pipeline = Pipelines::Create.call(project: project, title: title).value
      pipeline.update!(status: status)
      pipeline
    end
  end
end
