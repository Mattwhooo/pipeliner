require "test_helper"

module Projects
  class CreateTest < ActiveSupport::TestCase
    test "creates a project with the creator as owner" do
      result = Projects::Create.call(owner: users(:dev), attributes: {
        name: "New app", repo_url: "https://github.com/example/new-app"
      })

      assert result.success?
      project = result.value
      assert_equal "pending", project.env_status
      membership = project.memberships.sole
      assert_equal users(:dev), membership.user
      assert_equal "owner", membership.role
    end

    test "fails with :invalid on duplicate repo_url and creates no membership" do
      assert_no_difference [ "Project.count", "Membership.count" ] do
        result = Projects::Create.call(owner: users(:dev), attributes: {
          name: "Dup", repo_url: projects(:pipeliner).repo_url
        })
        assert result.failure?
        assert_equal :invalid, result.error
      end
    end
  end
end
