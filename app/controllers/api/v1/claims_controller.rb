module Api
  module V1
    # Pull-based work dispatch: a worker polls here to claim one ready step run
    # its roles make it eligible for. 200 + context bundle, or 204 (no work).
    class ClaimsController < BaseController
      def create
        result = StepRuns::Claim.call(worker: current_worker)

        if result.success?
          render json: StepRuns::ContextBundle.build(result.value), status: :ok
        else
          head :no_content
        end
      end
    end
  end
end
