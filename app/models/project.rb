class Project < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :pipelines, dependent: :destroy
  has_many :step_templates, dependent: :destroy
  has_many :project_assessments, dependent: :destroy
  has_one :pipeline_template, dependent: :destroy

  enum :env_status, {
    pending: "pending",
    assessing: "assessing",
    ready: "ready",
    needs_setup: "needs_setup"
  }, prefix: :env

  validates :name, presence: true
  validates :repo_url, presence: true, uniqueness: true
  validates :default_branch, presence: true
  validates :project_type, presence: true

  # `owner/repo` when repo_url is a github.com remote (git@ or https form, with
  # or without a trailing .git), else nil. A local-hub project (bare-repo path)
  # has no slug, which is what makes `github?` false. Kept here because it is a
  # simple intrinsic derivation of repo_url (backend-guide "Models own simple
  # derivations"); Finalize, MergePr and the GitHub adapter all read it.
  def github_slug
    return nil if repo_url.blank?

    case repo_url
    when %r{\Agit@github\.com:(?<slug>[^/].*?)(?:\.git)?\z},
         %r{\Ahttps?://github\.com/(?<slug>[^/].*?)(?:\.git)?\z}
      Regexp.last_match(:slug)
    end
  end

  def github? = github_slug.present?
end
