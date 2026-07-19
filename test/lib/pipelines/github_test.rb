require "test_helper"

module Pipelines
  # Unit-tests the gh adapter's command shaping + output parsing by swapping the
  # private `run` shell-out (no mocking library in this repo — replace + restore
  # the singleton method directly, like AdvanceTest). gh and the network are
  # NEVER invoked.
  class GithubTest < ActiveSupport::TestCase
    test "ready? is true only when gh is available and authenticated" do
      with_singleton(Github, :available?, -> { true }) do
        with_singleton(Github, :authenticated?, -> { true }) { assert Github.ready? }
        with_singleton(Github, :authenticated?, -> { false }) { assert_not Github.ready? }
      end
      with_singleton(Github, :available?, -> { false }) do
        with_singleton(Github, :authenticated?, -> { true }) { assert_not Github.ready? }
      end
    end

    test "create_pr returns the trailing url and parsed number on success" do
      output = "Warning: 3 uncommitted changes\nhttps://github.com/acme/widgets/pull/42\n"
      with_run(->(*_cmd) { [ output, true ] }) do
        response = Github.create_pr(repo: "acme/widgets", base: "main",
          head: "pipeliner/pl_x", title: "Feature", body: "Body")
        assert response.ok?
        assert_equal "https://github.com/acme/widgets/pull/42", response.url
        assert_equal 42, response.number
      end
    end

    test "create_pr surfaces gh's error output on failure" do
      with_run(->(*_cmd) { [ "pull request already exists", false ] }) do
        response = Github.create_pr(repo: "acme/widgets", base: "main",
          head: "b", title: "t", body: "b")
        assert_not response.ok?
        assert_equal "pull request already exists", response.error
      end
    end

    test "merge_pr passes the number and strategy flag and reports success" do
      captured = []
      with_run(->(*cmd) { captured = cmd; [ "", true ] }) do
        response = Github.merge_pr(repo: "acme/widgets", number: 42, method: "squash")
        assert response.ok?
      end
      assert_equal [ "gh", "pr", "merge", "42", "--repo", "acme/widgets", "--squash" ], captured
    end

    test "merge_pr surfaces gh's error on failure" do
      with_run(->(*_cmd) { [ "not mergeable: conflicts", false ] }) do
        response = Github.merge_pr(repo: "acme/widgets", number: 42)
        assert_not response.ok?
        assert_equal "not mergeable: conflicts", response.error
      end
    end

    private

    def with_run(impl, &block) = with_singleton(Github, :run, impl, &block)

    def with_singleton(klass, name, impl)
      original = klass.method(name)
      klass.define_singleton_method(name, impl)
      yield
    ensure
      klass.singleton_class.send(:remove_method, name)
      klass.define_singleton_method(name, original)
    end
  end
end
