class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  enum :role, { owner: "owner", admin: "admin", member: "member" }, suffix: true

  validates :user_id, uniqueness: { scope: :project_id }
end
