module PhasesHelper
  # Critic verdict → semantic tone (guides/ui-style-guide.md). Verdicts live in a
  # separate namespace from run/phase status, so they get their own small map
  # rather than being folded into StatusHelper::STATUS_TONES.
  VERDICT_TONES = {
    "pass" => :success,
    "needs_work" => :attention,
    "not_applicable" => :muted
  }.freeze

  # Finding severity → tone. blocker/major demand attention, minor is muted.
  SEVERITY_TONES = {
    "blocker" => :danger,
    "major" => :attention,
    "minor" => :muted
  }.freeze

  def verdict_badge(verdict_status)
    tone = VERDICT_TONES.fetch(verdict_status.to_s, :muted)
    pill(verdict_status.to_s.humanize, tone)
  end

  def severity_badge(severity)
    tone = SEVERITY_TONES.fetch(severity.to_s, :muted)
    pill(severity.to_s.humanize, tone)
  end

  private

  def pill(label, tone)
    tag.span(label,
      class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset #{StatusHelper::TONE_CLASSES[tone]}")
  end
end
