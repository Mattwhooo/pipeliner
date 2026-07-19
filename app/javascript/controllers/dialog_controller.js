import { Controller } from "@hotwired/stimulus"

// Small, generic opener/closer for a native <dialog>. Escape-to-close and
// focus return are free from the browser; this only handles explicit
// open/close triggers and dismissing via a backdrop click.
export default class extends Controller {
  static targets = ["dialog"]

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
