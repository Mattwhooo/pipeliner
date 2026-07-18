require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "index lists the user's projects" do
    get projects_url
    assert_response :success
    assert_select "td", text: "Pipeliner"
  end

  test "show renders the project with its pipelines" do
    get project_url(projects(:pipeliner))
    assert_response :success
    assert_select "h1", "Pipeliner"
    assert_select "td a", text: pipelines(:onboarding).title
  end

  test "create redirects to the new project" do
    post projects_url, params: { project: {
      name: "Wiki", repo_url: "https://github.com/example/wiki",
      default_branch: "main", project_type: "wiki"
    } }
    assert_redirected_to project_url(Project.find_by!(name: "Wiki"))
  end

  test "invalid create re-renders the form" do
    post projects_url, params: { project: { name: "", repo_url: "" } }
    assert_response :unprocessable_entity
  end

  test "cannot see a project the user is not a member of" do
    project = Project.create!(name: "Other", repo_url: "https://github.com/example/other")
    get project_url(project)
    assert_response :not_found
  end
end
