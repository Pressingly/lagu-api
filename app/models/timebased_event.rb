# frozen_string_literal: true

class TimebasedEvent < ApplicationRecord
  include PaperTrailTraceable
  include Discard::Model
  self.discard_column = :deleted_at

  belongs_to :billable_metric, optional: true
  belongs_to :organization
  belongs_to :invoice, optional: true
end
