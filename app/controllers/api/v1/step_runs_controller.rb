module Api
  module V1
    class StepRunsController < BaseController
      before_action :set_step_run

      # Renews the lease; response carries the cooperative-cancel flag.
      def heartbeat
        result = StepRuns::Heartbeat.call(
          step_run: @step_run, worker: current_worker,
          epoch: params[:epoch], roles: params[:roles]
        )
        render json: result.value
      end

      def progress
        result = StepRuns::RecordProgress.call(
          step_run: @step_run, worker: current_worker,
          epoch: params[:epoch], progress: params[:progress]&.to_unsafe_h
        )

        if result.success?
          head :ok
        else
          render json: { error: result.error }, status: :conflict
        end
      end

      def complete
        result = StepRuns::Complete.call(
          step_run: @step_run, worker: current_worker,
          epoch: params[:epoch], status: params[:status],
          result: params[:result]&.to_unsafe_h,
          verdict: params[:verdict]&.to_unsafe_h,
          commit_sha: params[:commit_sha]
        )

        if result.success?
          head :ok
        else
          render json: { error: result.error }, status: :conflict
        end
      end

      private

      def set_step_run
        @step_run = StepRun.find(params[:id])
      end
    end
  end
end
