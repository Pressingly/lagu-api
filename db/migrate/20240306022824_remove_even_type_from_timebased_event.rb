# frozen_string_literal: true

class RemoveEvenTypeFromTimebasedEvent < ActiveRecord::Migration[7.0]
  def change
    remove_column :timebased_events, :event_type, :integer
  end
end
