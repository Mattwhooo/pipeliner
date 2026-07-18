# Uniform return value for all services (see guides/backend-guide.md).
#
#   result = Pipelines::Create.call(...)
#   result.success? # => true/false
#   result.value    # payload on success (often the record)
#   result.error    # symbol on failure (e.g. :invalid)
#   result.record   # the record involved, when useful on failure too
class Result
  attr_reader :value, :error, :record

  def self.success(value = nil)
    new(success: true, value: value, record: value)
  end

  def self.failure(error, record: nil)
    new(success: false, error: error, record: record)
  end

  def initialize(success:, value: nil, error: nil, record: nil)
    @success = success
    @value = value
    @error = error
    @record = record
  end

  def success? = @success
  def failure? = !@success
end
