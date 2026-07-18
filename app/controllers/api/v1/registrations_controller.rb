module Api
  module V1
    # Worker self-registration. Authenticated by the shared registration key
    # (config.x.worker_registration_key), not a worker token — this is where
    # the worker token comes from. The plaintext token is returned once.
    class RegistrationsController < ActionController::API
      def create
        unless valid_registration_key?
          return render json: { error: "unauthorized" }, status: :unauthorized
        end

        result = Workers::Register.call(
          public_id: registration_params[:public_id],
          name: registration_params[:name],
          backend: registration_params[:backend],
          model: registration_params[:model],
          roles: registration_params[:roles] || [],
          concurrency: registration_params[:concurrency] || 1
        )

        if result.success?
          worker = result.value[:worker]
          render json: {
            worker: { public_id: worker.public_id, name: worker.name },
            token: result.value[:token],
            heartbeat_interval: 15,
            lease_ttl: StepRuns::Claim::LEASE_TTL.to_i
          }, status: :created
        else
          render json: { error: "invalid", details: result.record.errors.full_messages },
            status: :unprocessable_entity
        end
      end

      private

      def valid_registration_key?
        expected = Rails.application.config.x.worker_registration_key
        provided = request.headers["X-Registration-Key"]
        expected.present? && provided.present? &&
          ActiveSupport::SecurityUtils.secure_compare(provided, expected)
      end

      def registration_params
        params.expect(worker: [ :public_id, :name, :backend, :model, :concurrency, roles: [] ])
      end
    end
  end
end
