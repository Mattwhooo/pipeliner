class ArtifactRef < ApplicationRecord
  belongs_to :pipeline

  enum :kind, { artifact: "artifact", repo: "repo" }, suffix: true

  validates :phase_kind, presence: true
  validates :name, presence: true
end
