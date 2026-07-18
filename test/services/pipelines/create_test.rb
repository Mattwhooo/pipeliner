require "test_helper"

module Pipelines
  class CreateTest < ActiveSupport::TestCase
    test "creates a pipeline with its four fixed phases in order" do
      result = Pipelines::Create.call(project: projects(:pipeliner), title: "Do a thing")

      assert result.success?
      pipeline = result.value
      assert_equal %w[define plan build review], pipeline.phases.map(&:kind)
      assert_equal [ 1, 2, 3, 4 ], pipeline.phases.map(&:position)
      assert_equal "draft", pipeline.status
      assert_match(/\Apipeliner\/pl_[a-z0-9]{8}\z/, pipeline.branch)
    end

    test "fails with :invalid when title is missing" do
      result = Pipelines::Create.call(project: projects(:pipeliner), title: "")

      assert result.failure?
      assert_equal :invalid, result.error
      assert result.record.errors[:title].any?
    end

    test "creates nothing when the transaction fails" do
      assert_no_difference [ "Pipeline.count", "Phase.count" ] do
        Pipelines::Create.call(project: projects(:pipeliner), title: "")
      end
    end
  end
end
