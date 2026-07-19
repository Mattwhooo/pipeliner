module Dashboard
  # Active pipelines for a user's dashboard: attention-first, then
  # most-recently-active, capped, alongside the headline counts the summary
  # panel needs. One entry point (#call) materializes everything a caller
  # needs — nothing is left lazy for a view to trigger later.
  class ActivePipelines
    ACTIVE_STATUSES = %w[running awaiting_human blocked stuck].freeze
    LIMIT = 10

    Row = Struct.new(:pipeline, :attention, :attention_reason,
                      :last_active_at, keyword_init: true)
    Data = Struct.new(:rows, :total_count, :attention_count, keyword_init: true)

    def initialize(user)
      @user = user
    end

    def call
      all_rows = base_scope.map { |pipeline| build_row(pipeline) }
      sorted = all_rows.sort_by { |row| [ row.attention ? 0 : 1, -row.last_active_at.to_i ] }
      Data.new(
        rows: sorted.first(LIMIT),
        total_count: all_rows.size,
        attention_count: all_rows.count(&:attention)
      )
    end

    # One row, recomputed — used by Dashboard::Broadcast for a targeted
    # partial replace. Returns nil if the pipeline is no longer active/visible
    # to this user, so the broadcast can remove the row instead of stale-
    # replacing it.
    def row_for(pipeline)
      build_row(pipeline) if base_scope.exists?(pipeline.id)
    end

    private

    def base_scope
      Pipeline.joins(project: :memberships)
        .where(memberships: { user_id: @user.id })
        .where(status: ACTIVE_STATUSES)
        .includes(:project, phases: { workflows: { steps: :step_runs } })
        .distinct
    end

    def build_row(pipeline)
      Row.new(
        pipeline: pipeline,
        attention: attention?(pipeline),
        attention_reason: attention_reason(pipeline),
        last_active_at: last_active_at(pipeline)
      )
    end

    def attention?(pipeline)
      pipeline.awaiting_human? || pipeline.blocked? || pipeline.stuck? || current_phase_stuck?(pipeline)
    end

    # :awaiting_human vs :stuck are two different visual treatments (R13/R14).
    def attention_reason(pipeline)
      return :awaiting_human if pipeline.awaiting_human?
      return :stuck if pipeline.blocked? || pipeline.stuck? || current_phase_stuck?(pipeline)

      nil
    end

    def current_phase_stuck?(pipeline)
      current = pipeline.phases.detect { |phase| phase.kind == pipeline.current_phase }
      return false unless current

      current.workflows.any? { |workflow| workflow.steps.any? { |step| step.step_runs.any? { |run| run.state == "stuck" } } }
    end

    # A running step's progress ticks don't touch the pipeline row, so
    # `pipeline.updated_at` alone under-reports; fold in the latest step_run
    # activity across every phase.
    def last_active_at(pipeline)
      timestamps = [ pipeline.updated_at ]
      pipeline.phases.each do |phase|
        phase.workflows.each do |workflow|
          workflow.steps.each do |step|
            step.step_runs.each do |run|
              timestamps << (run.last_heartbeat_at || run.updated_at)
            end
          end
        end
      end
      timestamps.compact.max
    end
  end
end
