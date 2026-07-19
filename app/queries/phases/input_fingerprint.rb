require "digest"

module Phases
  # Deterministic content-identity of everything a step would consume on a fresh
  # dispatch: its declared input artifacts, the outputs of its worker
  # predecessors, and the feedback being routed to it. Two dispatches with the
  # same fingerprint would hand the worker a byte-identical input.json, so the
  # step's last succeeded run still stands and the Manager can reuse it instead of
  # re-running the worker (docs/execution-model.md — "Skip re-running unchanged
  # steps"; ManagerTick#dispatch_ready_steps).
  #
  # Content identity is taken from the *producing merge commit*, never re-read
  # from git: an artifact re-merged with new content gets a new commit_sha
  # (ArtifactRef is re-indexed on every merge), and a predecessor that really
  # re-ran produces a new merge commit — while a predecessor the Manager *reused*
  # copies its source's commit_sha, so its identity is unchanged. This makes the
  # only unsafe direction impossible: a genuine change can never look unchanged.
  # At worst a no-op re-merge (new sha, same bytes) looks changed and costs an
  # avoidable re-run — the safe way to be wrong.
  class InputFingerprint
    def self.for(step, feedback:)
      new(step, feedback:).digest
    end

    def initialize(step, feedback:)
      @step = step
      @feedback = feedback
      @pipeline = step.workflow.phase.pipeline
    end

    def digest
      Digest::SHA256.hexdigest(canonical.to_json)
    end

    private

    def canonical
      {
        "inputs" => declared_input_identities,
        "predecessors" => predecessor_identities,
        "feedback" => normalized_feedback
      }
    end

    # Each declared input artifact resolved to the commit(s) that last produced
    # it (by artifact name — the inter-phase contract; docs/artifact-schema.md).
    # Captures cross-phase dependencies a workflow's own `depends_on` edges don't,
    # e.g. a Review critic reading Define's business_requirements. Inputs with no
    # ArtifactRef (the initial ask, the codebase) contribute a stable nil.
    def declared_input_identities
      Array(@step.inputs).filter_map do |input|
        name = input.is_a?(Hash) ? input["artifact"].presence : nil
        next unless name

        [ name, @pipeline.artifact_refs.where(name: name)
          .order(:workflow_slug, :step_slug).pluck(:commit_sha) ]
      end.sort_by { |name, _| name }
    end

    # Each worker predecessor's current output identity — always available even
    # when a step declares no explicit inputs, and the signal that a re-dispatch
    # is downstream of an actually-changed artifact. A run with no commit
    # (nothing to merge) falls back to its own id so distinct runs never collide.
    def predecessor_identities
      @step.worker_predecessors.filter_map do |predecessor|
        run = predecessor.latest_run
        next unless run

        [ predecessor.slug, run.commit_sha.presence || "run-#{run.id}" ]
      end.sort_by { |slug, _| slug }
    end

    # Feedback entries are order-insensitive and key-order-insensitive maps, so
    # canonicalize before hashing (the same findings routed twice must match).
    def normalized_feedback
      Array(@feedback).map { |entry| entry.is_a?(Hash) ? entry.sort.to_h : entry }
        .sort_by(&:to_json)
    end
  end
end
