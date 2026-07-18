# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

if Rails.env.development?
  user = User.find_or_create_by!(email: "dev@pipeliner.local") do |u|
    u.password = "password123"
    u.password_confirmation = "password123"
  end
  puts "Seeded dev user: dev@pipeliner.local / password123"

  # Default project: Pipeliner itself (dogfooding).
  project = Project.find_by(repo_url: "https://github.com/mattwatson/pipeliner")
  if project.nil?
    result = Projects::Create.call(owner: user, attributes: {
      name: "Pipeliner",
      repo_url: "https://github.com/mattwatson/pipeliner",
      default_branch: "main",
      project_type: "software"
    })
    raise "Seed failed: #{result.record&.errors&.full_messages}" if result.failure?
    project = result.value
    puts "Seeded default project: #{project.name}"
  end

  # Default pipeline: a sensible first task so the app opens with real content.
  if project.pipelines.none?
    result = Pipelines::Create.call(
      project: project,
      title: "Add a CONTRIBUTING guide",
      initial_prompt: <<~PROMPT
        Add a CONTRIBUTING.md to the repository that explains how to propose a
        change: setting up the dev environment, following the design guides in
        guides/, running tests and rubocop, and what a good PR looks like.
      PROMPT
    )
    raise "Seed failed: #{result.record&.errors&.full_messages}" if result.failure?
    puts "Seeded default pipeline: #{result.value.title}"
  end
end
