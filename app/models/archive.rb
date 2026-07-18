class Archive < ApplicationRecord
  belongs_to :pipeline

  validates :s3_bucket, presence: true
  validates :s3_key, presence: true
end
