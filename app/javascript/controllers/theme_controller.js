import { Controller } from "@hotwired/stimulus"

// Toggles the "dark" class on <html> and persists the choice in a cookie.
// See app/views/shared/_theme_init_script.html.erb for the pre-paint theme
// application this controller keeps in sync after load.
export default class extends Controller {
  connect() {
    this.syncPressedState()

    if (!this.hasStoredPreference()) {
      this.media = window.matchMedia("(prefers-color-scheme: dark)")
      this.onSystemChange = () => {
        document.documentElement.classList.toggle("dark", this.media.matches)
        this.syncPressedState()
      }
      this.media.addEventListener("change", this.onSystemChange)
    }
  }

  disconnect() {
    if (this.media) this.media.removeEventListener("change", this.onSystemChange)
  }

  toggle() {
    const dark = !document.documentElement.classList.contains("dark")
    document.documentElement.classList.toggle("dark", dark)
    document.cookie = `theme=${dark ? "dark" : "light"}; path=/; max-age=31536000; SameSite=Lax`
    this.syncPressedState()
  }

  syncPressedState() {
    this.element.setAttribute("aria-pressed", document.documentElement.classList.contains("dark"))
  }

  hasStoredPreference() {
    return /(?:^|; )theme=(dark|light)/.test(document.cookie)
  }
}
