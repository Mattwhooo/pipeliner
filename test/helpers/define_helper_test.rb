require "test_helper"

class DefineHelperTest < ActionView::TestCase
  include DefineHelper

  setup do
    @define = phases(:onboarding_define)
    @requirements = steps(:requirements_writer)
    step_runs(:requirements_ready).destroy
  end

  test "define_discovery_notes returns the latest succeeded run's artifact" do
    @requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements",
      result: { "artifacts" => { "discovery_notes" => "What exists today..." } })

    assert_equal "What exists today...", define_discovery_notes(@define)
  end

  test "define_business_requirements returns the latest succeeded run's artifact" do
    @requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements",
      result: { "artifacts" => { "business_requirements" => "R1: ..." } })

    assert_equal "R1: ...", define_business_requirements(@define)
  end

  test "define_open_questions returns nil when nothing has produced it yet" do
    assert_nil define_open_questions(@define)
  end

  test "artifact helpers pick the latest run when there are several" do
    @requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements",
      result: { "artifacts" => { "business_requirements" => "old" } })
    @requirements.step_runs.create!(state: "succeeded", iteration: 2, required_role: "requirements",
      result: { "artifacts" => { "business_requirements" => "fresh (restarted)" } })

    assert_equal "fresh (restarted)", define_business_requirements(@define)
  end

  test "define_menu_failure surfaces the most recent failed run's summary" do
    @requirements.step_runs.create!(state: "failed", iteration: 1, required_role: "requirements",
      result: { "summary" => "worker crashed mid-run" })

    assert_equal "worker crashed mid-run", define_menu_failure(@define)
  end

  test "define_menu_failure is nil when nothing has failed" do
    @requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements")
    assert_nil define_menu_failure(@define)
  end
end
