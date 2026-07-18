require "test_helper"

class WorkerTest < ActiveSupport::TestCase
  test "supports_role? matches against supported_roles" do
    worker = workers(:claude_local)
    assert worker.supports_role?("code")
    assert_not worker.supports_role?("ui-tests")
  end

  test "public_id must be unique" do
    dup = Worker.new(public_id: workers(:claude_local).public_id,
      auth_token_digest: "x")
    assert_not dup.valid?
    assert dup.errors[:public_id].any?
  end
end
