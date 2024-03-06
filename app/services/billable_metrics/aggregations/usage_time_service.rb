# frozen_string_literal: true

module BillableMetrics
  module Aggregations
    class UsageTimeService < BillableMetrics::Aggregations::BaseService
      def aggregate(options: {})
        result.aggregation = compute_aggregation
        result.count = result.aggregation
        result.current_usage_units = result.aggregation
        result.pay_in_advance_aggregation = BigDecimal(1)
        result.options = options
        result
      end

      def compute_aggregation
        1
      end
    end
  end
end
