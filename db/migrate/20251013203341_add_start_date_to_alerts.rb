class AddStartDateToAlerts < ActiveRecord::Migration[5.0]
  def change
    add_column :alerts, :start_date, :datetime
  end
end
