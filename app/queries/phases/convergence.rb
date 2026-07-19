module Phases
  # Read-only: is a phase's work settled? Same rule ManagerTick uses to declare
  # consensus (all worker steps succeeded+merged, every critic pass/n_a) — but
  # callable on demand with no side effects, so Approve can ask it live for a
  # phase that isn't being ticked (paused phases aren't) — R20/R21.
  class Convergence
    RESOLVED_VERDICTS = %w[pass not_applicable].freeze

    def self.phase_settled?(phase)
      workflows = phase.workflows.to_a
      workflows.present? && workflows.all? { |w| workflow_converged?(w) }
    end

    def self.workflow_converged?(workflow)
      worker_steps = workflow.steps.select(&:worker_executed?)
      return false if worker_steps.empty?
      return false unless worker_steps.all? { |s| s.latest_run&.succeeded? && s.latest_run.merged? }

      worker_steps.select(&:type_critic?).all? do |critic|
        RESOLVED_VERDICTS.include?(critic.latest_run.verdict_status)
      end
    end
  end
end
