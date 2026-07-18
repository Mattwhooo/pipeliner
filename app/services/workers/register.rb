module Workers
  # Registers (or re-registers) a Worker and issues its bearer token.
  # A worker keeps a stable public_id across restarts; re-registering with the
  # same public_id rotates the token and refreshes its advertised properties.
  # The plaintext token is returned exactly once per (re)registration.
  class Register
    def self.call(public_id:, name: nil, backend: nil, model: nil, roles: [], concurrency: 1)
      new(public_id:, name:, backend:, model:, roles:, concurrency:).call
    end

    def initialize(public_id:, name:, backend:, model:, roles:, concurrency:)
      @public_id = public_id
      @name = name
      @backend = backend
      @model = model
      @roles = Array(roles).map(&:to_s)
      @concurrency = concurrency
    end

    def call
      token = "wt_#{SecureRandom.hex(24)}"

      worker = Worker.find_or_initialize_by(public_id: @public_id)
      worker.assign_attributes(
        name: @name,
        backend: @backend,
        model: @model,
        supported_roles: @roles,
        concurrency: @concurrency,
        status: "online",
        last_heartbeat_at: Time.current,
        auth_token_digest: Digest::SHA256.hexdigest(token)
      )
      worker.save!

      Result.success({ worker: worker, token: token })
    rescue ActiveRecord::RecordInvalid
      Result.failure(:invalid, record: worker)
    end
  end
end
