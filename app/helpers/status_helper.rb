module StatusHelper
  # Semantic status colors per guides/ui-style-guide.md. Color never carries
  # meaning alone — the status word is always shown.
  STATUS_TONES = {
    # running / in progress → blue
    "running" => :info, "assessing" => :info, "claimed" => :info,
    # success → green
    "ready" => :success, "approved" => :success, "completed" => :success,
    "converged" => :success, "succeeded" => :success, "passed" => :success,
    "online" => :success, "consensus" => :success,
    # needs attention → amber
    "awaiting_human" => :attention, "needs_setup" => :attention,
    "reworking" => :attention, "draining" => :attention,
    # stuck / failed → red
    "stuck" => :danger, "failed" => :danger, "blocked" => :danger,
    "aborted" => :danger,
    # pending / idle → gray
    "pending" => :muted, "draft" => :muted, "offline" => :muted
  }.freeze

  TONE_CLASSES = {
    info: "bg-blue-50 text-blue-700 ring-blue-600/20 dark:bg-blue-500/10 dark:text-blue-400 dark:ring-blue-400/20",
    success: "bg-green-50 text-green-700 ring-green-600/20 dark:bg-green-500/10 dark:text-green-400 dark:ring-green-400/20",
    attention: "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-500/10 dark:text-amber-400 dark:ring-amber-400/20",
    danger: "bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-500/10 dark:text-red-400 dark:ring-red-400/20",
    muted: "bg-gray-50 text-gray-600 ring-gray-500/20 dark:bg-gray-500/10 dark:text-gray-400 dark:ring-gray-400/20"
  }.freeze

  def status_badge(status, label: nil)
    tone = STATUS_TONES.fetch(status.to_s, :muted)
    tag.span(label || status.to_s.humanize,
      class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset #{TONE_CLASSES[tone]}")
  end
end
