import { Controller } from "@hotwired/stimulus"

const COOKIE_NAME = "theme"
const COOKIE_MAX_AGE = 60 * 60 * 24 * 365 // 1 year

// Toggles the "dark" class on <html> and remembers a manual choice in a
// cookie. Absence of the cookie means "follow the system setting" — see
// guides/ui-style-guide.md §Color and the theme init script for the
// zero-flash counterpart of this logic.
export default class extends Controller {
  connect() {
    this.syncPressedState()

    if (!this.readCookie()) {
      this.media = window.matchMedia("(prefers-color-scheme: dark)")
      this.onSystemChange = (event) => {
        if (this.readCookie()) return // a manual choice was made since connect()

        document.documentElement.classList.toggle("dark", event.matches)
        this.syncPressedState()
      }
      this.media.addEventListener("change", this.onSystemChange)
    }
  }

  disconnect() {
    if (this.media) this.media.removeEventListener("change", this.onSystemChange)
  }

  toggle() {
    const isDark = !document.documentElement.classList.contains("dark")
    document.documentElement.classList.toggle("dark", isDark)
    this.writeCookie(isDark ? "dark" : "light")
    this.syncPressedState()
  }

  syncPressedState() {
    this.element.setAttribute("aria-pressed", document.documentElement.classList.contains("dark"))
  }

  readCookie() {
    const match = document.cookie.match(/(?:^|; )theme=(light|dark)/)
    return match ? match[1] : null
  }

  writeCookie(value) {
    document.cookie = `${COOKIE_NAME}=${value}; path=/; max-age=${COOKIE_MAX_AGE}; SameSite=Lax`
  }
}
