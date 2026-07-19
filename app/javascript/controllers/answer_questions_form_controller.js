import { Controller } from "@hotwired/stimulus"

// Composes one submission from the modal's per-question inputs: an
// untouched input contributes its default (placeholder), a typed input
// contributes its own value. Validates at least one answer was given before
// letting the form submit.
export default class extends Controller {
  static targets = ["form", "answer", "composed", "error"]

  submit(event) {
    const answered = this.answerTargets.filter((input) => input.value.trim() !== "")
    if (answered.length === 0) {
      event.preventDefault()
      this.showError(
        "Add at least one answer, or approve the pipeline to accept every default as-is."
      )
      return
    }

    this.hideError()
    this.composedTarget.value = this.answerTargets
      .map((input, index) => {
        const answer = input.value.trim() || input.placeholder
        return `Q${index + 1}: ${input.dataset.question}\nA${index + 1}: ${answer}`
      })
      .join("\n\n")
  }

  // Turbo fires turbo:submit-end after the fetch resolves; close on success
  // only, leaving the (still-populated) form open on failure. This
  // controller's own element is the <dialog> (see the modal partial).
  closeOnSuccess(event) {
    if (event.detail.success) this.element.close()
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    this.errorTarget.classList.add("hidden")
  }
}
