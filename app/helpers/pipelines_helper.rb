module PipelinesHelper
  # Solid dot color for the live status summary, derived from the same semantic
  # tone the status badge uses (StatusHelper) so color stays centralized and
  # never diverges from the badge (guides/ui-style-guide.md; R17). The dot only
  # echoes the tone — the summary sentence carries the meaning.
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
