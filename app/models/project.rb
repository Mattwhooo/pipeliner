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
end
