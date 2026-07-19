require "test_helper"

module Dashboard
  class BroadcastTest < ActiveSupport::TestCase
    include ActionCable::TestHelper

    setup do
      @pipeline = pipelines(:onboarding)
      @user = users(:dev)
    end

    test "broadcasts the pipeline row and summary to every project member" do
      other_user = User.create!(email: "teammate@example.com", password: "password123")
      @pipeline.project.memberships.create!(user: other_user, role: "member")

      assert_broadcasts(stream_for(@user), 2) do
        assert_broadcasts(stream_for(other_user), 2) do
          Broadcast.call(pipeline: @pipeline)
        end
      end
    end

    test "activity: false does not touch the recent-activity target" do
      messages = decoded_broadcasts_on(stream_for(@user)) { Broadcast.call(pipeline: @pipeline, activity: false) }
      assert_equal 2, messages.size
      assert messages.none? { |message| message.include?('target="recent-activity"') }
    end

    test "activity: true additionally replaces the recent-activity target" do
      messages = decoded_broadcasts_on(stream_for(@user)) { Broadcast.call(pipeline: @pipeline, activity: true) }
      assert_equal 3, messages.size
      assert messages.any? { |message| message.include?('target="recent-activity"') }
    end

    test "a pipeline that is no longer active is removed rather than replaced" do
      @pipeline.update!(status: "completed")
      messages = decoded_broadcasts_on(stream_for(@user)) { Broadcast.call(pipeline: @pipeline) }
      target = ActionView::RecordIdentifier.dom_id(@pipeline, :dashboard_row)
      assert messages.any? { |message| message.include?(%(action="remove")) && message.include?(%(target="#{target}")) }
    end

    # F3 regression guard: three call sites (Approve, ManagerTick,
    # ReworkToPhase) accumulate state during a transaction and must fan the
    # dashboard broadcast out only AFTER that transaction commits. Forcing
    # the broadcast to raise proves the preceding writes already committed —
    # if they hadn't, the raise (unwound through the still-open transaction)
    # would have rolled them back too.
    test "Approve's broadcast fires only after its transaction commits" do
      define = phases(:onboarding_define)
      define.update!(status: "consensus")
      boom = Class.new(StandardError)
      original = Dashboard::Broadcast.method(:call)

      Dashboard::Broadcast.define_singleton_method(:call) { |**| raise boom }
      begin
        assert_raises(boom) { Phases::Approve.call(phase: define, user: @user) }
      ensure
        Dashboard::Broadcast.define_singleton_method(:call, original)
      end

      define.reload
      assert_equal "approved", define.status
      assert define.approvals.exists?(decision: "approve")
    end

    test "ReworkToPhase's broadcast fires only after its transaction commits" do
      from_phase = phases(:onboarding_build)
      target_phase = phases(:onboarding_define)
      boom = Class.new(StandardError)
      original = Dashboard::Broadcast.method(:call)

      Dashboard::Broadcast.define_singleton_method(:call) { |**| raise boom }
      begin
        assert_raises(boom) do
          Phases::ReworkToPhase.call(from_phase: from_phase, target_phase: target_phase,
            findings: [], reason: "test", mode: "automated", raised_by: "agent")
        end
      ensure
        Dashboard::Broadcast.define_singleton_method(:call, original)
      end

      target_phase.reload
      assert_equal "running", target_phase.status
      assert_equal 1, target_phase.rework_count
      assert_equal 1, @pipeline.reload.rework_events.count
    end

    private

    def stream_for(user)
      Turbo::StreamsChannel.send(:stream_name_from, [ user, :dashboard ])
    end

    def decoded_broadcasts_on(stream)
      old = broadcasts(stream)
      clear_messages(stream)
      yield
      new_messages = broadcasts(stream)
      clear_messages(stream)
      old.each { |m| pubsub_adapter.broadcast(stream, m) }
      new_messages.map { |m| ActiveSupport::JSON.decode(m) }
    end
  end
end
