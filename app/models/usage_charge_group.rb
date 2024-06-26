# frozen_string_literal: true

class UsageChargeGroup < ApplicationRecord
  include PaperTrailTraceable
  include Discard::Model
  self.discard_column = :deleted_at

  belongs_to :charge_group, -> { with_discarded }
  belongs_to :subscription

  # TODO: add details validations
  validates :current_package_count, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :charge_group_id, presence: true
  validates :subscription_id, presence: true
end
