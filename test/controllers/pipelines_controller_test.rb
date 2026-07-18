require "test_helper"

class PipelinesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "show renders the pipeline with its four phases" do
    get pipeline_url(pipelines(:onboarding))
    assert_response :success
    assert_select "h1", pipelines(:onboarding).title
    assert_select "h3", /Define/
    assert_select "h3", /Review/
  end

  test "create builds the pipeline and redirects to it" do
    post project_pipelines_url(projects(:pipeliner)), params: { pipeline: {
      title: "New work", initial_prompt: "Do the thing."
    } }
    pipeline = Pipeline.find_by!(title: "New work")
    assert_redirected_to pipeline_url(pipeline)
    assert_equal 4, pipeline.phases.count
  end

  test "invalid create re-renders the form" do
    post project_pipelines_url(projects(:pipeliner)), params: { pipeline: { title: "" } }
    assert_response :unprocessable_entity
  end
end
