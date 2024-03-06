# frozen_string_literal: true

class AddDeletedAtToTimebasedEvent < ActiveRecord::Migration[7.0]
  def change
    add_column :timebased_events, :deleted_at, :datetime
  end
end
