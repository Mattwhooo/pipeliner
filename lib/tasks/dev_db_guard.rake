# The development database is LIVE STATE for this app (the control plane
# orchestrating real pipelines). Agents — worker-spawned or otherwise — have
# now wiped it three times by loading test fixtures into it. This guard makes
# the destructive db tasks refuse to run against development unless a human
# explicitly overrides.
DESTRUCTIVE_DB_TASKS = %w[
  db:fixtures:load db:truncate_all db:seed:replant db:reset db:drop
  db:schema:load db:test:purge
].freeze

DESTRUCTIVE_DB_TASKS.each do |task_name|
  next unless Rake::Task.task_defined?(task_name)

  Rake::Task[task_name].enhance([ "pipeliner:guard_dev_db" ])
end

namespace :pipeliner do
  task guard_dev_db: :environment do
    next unless Rails.env.development?
    next if ENV["PIPELINER_ALLOW_DESTRUCTIVE"] == "1"

    abort "Refusing to run a destructive db task against the DEVELOPMENT " \
      "database — it holds the live control plane's state. If you really " \
      "mean it: PIPELINER_ALLOW_DESTRUCTIVE=1 bin/rails <task>"
  end
end
