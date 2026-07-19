module PipelinesHelper
  # Solid dot color for the live status summary, keyed by the same semantic tone
  # symbols StatusHelper uses (guides/ui-style-guide.md "Status colors"). Keeping
  # the mapping here — one place — means the dot can never drift from the reserved
  # status palette. The word beside the dot always carries the meaning; the dot
  # only reinforces it (a11y — status is never color alone).
  DOT_CLASSES = {
    info: "bg-blue-600",
    success: "bg-green-600",
    attention: "bg-amber-500",
    danger: "bg-red-600",
    muted: "bg-gray-400"
  }.freeze

  def summary_dot_class(tone)
    DOT_CLASSES.fetch(tone, DOT_CLASSES[:muted])
  end
end
