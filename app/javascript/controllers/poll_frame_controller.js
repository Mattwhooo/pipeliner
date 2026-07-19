import { Controller } from "@hotwired/stimulus"

// Reloads a <turbo-frame> on a fixed interval. Used where "live by default"
// is satisfied by a light periodic refresh rather than a broadcast.
export default class extends Controller {
  static values = { interval: { type: Number, default: 30000 } }

  connect() {
    this.timer = setInterval(() => this.element.reload(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}
