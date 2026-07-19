require "open3"
require "timeout"

module Pipelines
  # Thin adapter over the `gh` CLI — the single boundary between Pipeliner and
  # GitHub (backend-guide "app/lib for app-specific POROs that aren't
  # services/queries, e.g. a GitHub::Client wrapper"). Every method shells out to
  # `gh` and returns a Response value object; nothing here raises for a GitHub-side
  # failure (a non-mergeable PR, a missing auth) — that is data the calling
  # service turns into a Result. Services depend on this class by injection
  # (`github:` kwarg) so tests substitute a fake and NEVER touch the network.
  #
  # `gh` reads its own auth from the environment (`GH_TOKEN`/`gh auth login`); we
  # never pass credentials here.
  class Github
    GH_TIMEOUT = 60 # seconds — a create/merge round-trips to GitHub; bounded for a hang.

    # Immutable outcome of a gh invocation. `ok?` is the only success signal;
    # `url`/`number` are populated on a successful create, `error` on a failure.
    Response = Struct.new(:ok, :url, :number, :error, keyword_init: true) do
      def ok? = ok
    end

    class << self
      # gh present on PATH *and* authenticated — the precondition for any real
      # operation. Services fall back to a compare link when this is false.
      def ready?
        available? && authenticated?
      end

      def available?
        _out, ok = run("gh", "--version")
        ok
      end

      def authenticated?
        _out, ok = run("gh", "auth", "status")
        ok
      end

      # Opens a PR and returns its URL + number. gh prints warnings first and the
      # PR URL last, so we take the last http line as the URL.
      def create_pr(repo:, base:, head:, title:, body:)
        out, ok = run("gh", "pr", "create", "--repo", repo,
          "--base", base, "--head", head, "--title", title, "--body", body)
        return Response.new(ok: false, error: message(out, "gh pr create failed")) unless ok

        url = out.lines.map(&:strip).reverse.find { |line| line.start_with?("http") }
        Response.new(ok: true, url: url, number: number_from(url))
      end

      # Merges an existing PR by number. `method` is the merge strategy flag
      # (squash by default — see MergePr).
      def merge_pr(repo:, number:, method: "squash")
        out, ok = run("gh", "pr", "merge", number.to_s, "--repo", repo, "--#{method}")
        return Response.new(ok: false, error: message(out, "gh pr merge failed")) unless ok

        Response.new(ok: true)
      end

      private

      def number_from(url)
        url && url[%r{/pull/(\d+)\z}, 1]&.to_i
      end

      def message(out, fallback)
        out.to_s.strip.presence || fallback
      end

      def run(*command)
        out = nil
        status = nil
        Timeout.timeout(GH_TIMEOUT) { out, status = Open3.capture2e(*command) }
        [ out, status.success? ]
      rescue Timeout::Error
        [ "command timed out: #{command.join(" ")}", false ]
      rescue Errno::ENOENT
        # gh isn't installed at all — treat as an unavailable, not a crash.
        [ "gh executable not found", false ]
      end
    end
  end
end
