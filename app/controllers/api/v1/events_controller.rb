# frozen_string_literal: true

module Api
  module V1
    class EventsController < Api::BaseController
      def create
        result = ::Events::CreateService.call(
          organization: current_organization,
          params: create_params,
          timestamp: Time.current.to_f,
          metadata: event_metadata,
        )

        if result.success?
          render(
            json: ::V1::EventSerializer.new(
              result.event,
              root_name: 'event',
            ),
          )
        else
          render_error_response(result)
        end
      end

      def batch
        result = ::Events::CreateBatchService.call(
          organization: current_organization,
          events_params: batch_params,
          timestamp: Time.current.to_f,
          metadata: event_metadata,
        )

        if result.success?
          render(
            json: ::CollectionSerializer.new(
              result.events,
              ::V1::EventSerializer,
              collection_name: 'events',
            ),
          )
        else
          render_error_response(result)
        end
      end

      def show
        event = Event.find_by(
          organization: current_organization,
          transaction_id: params[:id],
        )

        return not_found_error(resource: 'event') unless event

        render(
          json: ::V1::EventSerializer.new(
            event,
            root_name: 'event',
          ),
        )
      end

      def estimate_fees
        result = Fees::EstimatePayInAdvanceService.call(
          organization: current_organization,
          params: create_params,
        )

        if result.success?
          render(
            json: ::CollectionSerializer.new(
              result.fees,
              ::V1::FeeSerializer,
              collection_name: 'fees',
              includes: %i[applied_taxes],
            ),
          )
        else
          render_error_response(result)
        end
      end

      def create_sync
        result = ::Events::CreateSyncService.call(
          organization: current_organization,
          params: create_params,
          timestamp: Time.current.to_f,
          metadata: event_metadata,
        )

        if result.success?
          event_json_str = ::V1::EventSerializer.new(
            result.event,
            root_name: 'event',
          ).to_json

          event_json = JSON.parse(event_json_str)

          if result.invoices.present?
            invoices_data = ::CollectionSerializer.new(
              result.invoices,
              ::V1::InvoiceSerializer,
              collection_name: 'invoices',
            ).to_json

            event_json['event']['invoices'] = JSON.parse(invoices_data)['invoices']
          end

          render(
            json: event_json,
          )
        else
          render_error_response(result)
        end
      end

      private

      def create_params
        params
          .require(:event)
          .permit(
            :transaction_id,
            :external_customer_id,
            :code,
            :timestamp,
            :external_subscription_id,
            properties: {},
          )
      end

      def batch_params
        params
          .permit(
            events: [
              :transaction_id,
              :external_customer_id,
              :code,
              :timestamp,
              :external_subscription_id,
              properties: {}, # rubocop:disable Style/HashAsLastArrayItem
            ],
          ).to_h.deep_symbolize_keys
      end

      def event_metadata
        {
          user_agent: request.user_agent,
          ip_address: request.remote_ip,
        }
      end

      def create_time_based_params
        params
          .require(:event)
          .permit(
            :external_customer_id,
            :external_subscription_id,
            :timestamp,
            event_type: :renew_subscription,
          )
      end
    end
  end
end
