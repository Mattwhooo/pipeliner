class StepToken < ApplicationRecord
  belongs_to :step_run

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true

  scope :active, -> { where(expires_at: Time.current..) }

  def expired?
    expires_at.past?
  end
end
