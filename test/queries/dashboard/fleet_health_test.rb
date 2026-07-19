require "test_helper"

module Dashboard
  class FleetHealthTest < ActiveSupport::TestCase
    setup do
      @worker = workers(:claude_local)
    end

    test "counts online and offline workers" do
      @worker.update!(status: "online")
      data = FleetHealth.new.call
      assert_equal 1, data[:online_count]
      assert_equal 0, data[:offline_count]
      assert_equal [ @worker ], data[:workers]
    end

    test "counts draining workers as offline" do
      @worker.update!(status: "draining")
      data = FleetHealth.new.call
      assert_equal 0, data[:online_count]
      assert_equal 1, data[:offline_count]
    end

    test "returns an empty role_gap when demand is covered" do
      @worker.update!(status: "online", supported_roles: [ "requirements" ])
      step_runs(:requirements_ready).update!(state: "ready", required_role: "requirements")
      data = FleetHealth.new.call
      assert_equal [], data[:role_gap]
    end

    test "flags roles that are demanded but no online worker supports" do
      @worker.update!(status: "offline")
      step_runs(:requirements_ready).update!(state: "stuck", required_role: "requirements")
      data = FleetHealth.new.call
      assert_equal [ "requirements" ], data[:role_gap]
    end

    test "returns an empty-but-valid hash with no workers registered" do
      Worker.destroy_all
      data = FleetHealth.new.call
      assert_equal [], data[:workers]
      assert_equal 0, data[:online_count]
      assert_equal 0, data[:offline_count]
    end
  end
end
