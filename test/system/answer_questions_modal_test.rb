require "application_system_test_case"

class AnswerQuestionsModalTest < ApplicationSystemTestCase
  setup do
    @pipeline = pipelines(:onboarding)
    @pipeline.update!(status: "awaiting_human")
    @define = phases(:onboarding_define)
    @define.update!(status: "consensus")
    @requirements = steps(:requirements_writer)
    step_runs(:requirements_ready).update!(state: "succeeded")
    @requirements.step_runs.create!(
      state: "succeeded", iteration: 2, required_role: "requirements",
      result: {
        "artifacts" => {
          "open_questions" => "1. Which auth provider?\n2. Which color scheme?",
          "open_questions_structured" => [
            { "question" => "Which auth provider?", "default" => "OAuth" },
            { "question" => "Which color scheme?", "default" => "Light" }
          ]
        }
      }
    )
    sign_in_as(users(:dev))
  end

  test "submitting composes typed answers and defaults together, then closes" do
    visit root_path
    click_on "Answer open questions"

    within "dialog[open]" do
      fill_in "Which auth provider?", with: "SAML"
      click_on "Send answers"
    end

    assert_no_selector "dialog[open]", wait: 5
    run = @requirements.step_runs.order(:iteration).last
    answer_text = run.feedback.first["issue"]
    assert_match "Q1: Which auth provider?\nA1: SAML", answer_text
    assert_match "Q2: Which color scheme?\nA2: Light", answer_text
  end

  test "pressing Escape dismisses the modal without sending any answers" do
    before_count = @requirements.step_runs.count
    visit root_path
    click_on "Answer open questions"
    assert_selector "dialog[open]"

    find("dialog[open]").send_keys(:escape)

    assert_no_selector "dialog[open]", wait: 5
    assert_equal before_count, @requirements.step_runs.count
  end

  test "submitting with every question left at its default is rejected" do
    visit root_path
    click_on "Answer open questions"

    within("dialog[open]") { click_on "Send answers" }

    assert_text "Add at least one answer", wait: 5
    assert_selector "dialog[open]"
  end

  private

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_on "Sign in"
    assert_selector "h1", text: "Dashboard", wait: 5
  end
end
