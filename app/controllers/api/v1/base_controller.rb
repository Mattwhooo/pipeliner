module Api
  module V1
    # Base for all worker-facing JSON endpoints. Auth is a worker-level bearer
    # token issued at registration; per-step tokens come later with the GitHub
    # integration (see docs/worker.md).
    class BaseController < ActionController::API
      before_action :authenticate_worker!

      private

      attr_reader :current_worker

      def authenticate_worker!
        token = request.authorization.to_s.delete_prefix("Bearer ").presence
        digest = token && Digest::SHA256.hexdigest(token)
        @current_worker = digest && Worker.find_by(auth_token_digest: digest)

        render json: { error: "unauthorized" }, status: :unauthorized unless @current_worker
      end
    end
  end
end
