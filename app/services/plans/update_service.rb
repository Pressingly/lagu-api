# frozen_string_literal: true

module Plans
  class UpdateService < BaseService
    def initialize(plan:, params:)
      @plan = plan
      @params = params
      super
    end

    def call
      return result.not_found_failure!(resource: 'plan') unless plan

      plan.name = params[:name] if params.key?(:name)
      plan.invoice_display_name = params[:invoice_display_name] if params.key?(:invoice_display_name)
      plan.description = params[:description] if params.key?(:description)

      # NOTE: Only name and description are editable if plan
      #       is attached to subscriptions
      unless plan.attached_to_subscriptions?
        plan.code = params[:code] if params.key?(:code)
        plan.interval = params[:interval].to_sym if params.key?(:interval)
        plan.pay_in_advance = params[:pay_in_advance] if params.key?(:pay_in_advance)
        plan.amount_cents = params[:amount_cents] if params.key?(:amount_cents)
        plan.amount_currency = params[:amount_currency] if params.key?(:amount_currency)
        plan.trial_period = params[:trial_period] if params.key?(:trial_period)
        plan.bill_charges_monthly = bill_charges_monthly?
      end

      if params[:charges].present?
        metric_ids = params[:charges].map { |c| c[:billable_metric_id] }.uniq
        if metric_ids.present? && organization.billable_metrics.where(id: metric_ids).count != metric_ids.count
          return result.not_found_failure!(resource: 'billable_metrics')
        end
      end

      ActiveRecord::Base.transaction do
        plan.save!

        if params[:tax_codes]
          taxes_result = Plans::ApplyTaxesService.call(plan:, tax_codes: params[:tax_codes])
          return taxes_result unless taxes_result.success?
        end

        if params[:charge_groups] && params[:charges]
          process_charge_groups(plan, params[:charge_groups], params[:charges])
        end
      end

      result.plan = plan
      result
    rescue ActiveRecord::RecordInvalid => e
      result.record_validation_failure!(record: e.record)
    end

    private

    attr_reader :plan, :params

    delegate :organization, to: :plan

    def bill_charges_monthly?
      return unless params[:interval]&.to_sym == :yearly

      params[:bill_charges_monthly] || false
    end

    def create_charge(plan, params)
      charge = plan.charges.new(
        billable_metric_id: params[:billable_metric_id],
        invoice_display_name: params[:invoice_display_name],
        amount_currency: params[:amount_currency],
        charge_model: charge_model(params),
        pay_in_advance: params[:pay_in_advance] || false,
        prorated: params[:prorated] || false,
        properties: params[:properties].presence || Charges::BuildDefaultPropertiesService.call(charge_model(params)),
        group_properties: (params[:group_properties] || []).map { |gp| GroupProperty.new(gp) },
        charge_group_id: params[:charge_group_id] || nil,
      )

      if License.premium?
        charge.invoiceable = params[:invoiceable] unless params[:invoiceable].nil?
        charge.min_amount_cents = params[:min_amount_cents] || 0
      end

      charge.save!

      if params[:tax_codes]
        taxes_result = Charges::ApplyTaxesService.call(charge:, tax_codes: params[:tax_codes])
        taxes_result.raise_if_error!
      end

      charge
    end

    def charge_model(params)
      model = params[:charge_model]&.to_sym
      return if model == :graduated_percentage && !License.premium?

      model
    end

    def process_charges(plan, params_charges)
      created_charges_ids = []

      hash_charges = params_charges.map { |c| c.to_h.deep_symbolize_keys }
      hash_charges.each do |payload_charge|
        charge = plan.charges.find_by(id: payload_charge[:id])

        if charge
          group_properties = payload_charge.delete(:group_properties)
          if group_properties.present?
            group_result = GroupProperties::CreateOrUpdateBatchService.call(
              charge:,
              properties_params: group_properties,
            )
            return group_result if group_result.error
          end

          properties = payload_charge.delete(:properties)
          charge.update!(
            invoice_display_name: payload_charge[:invoice_display_name],
            properties: properties.presence || Charges::BuildDefaultPropertiesService.call(
              payload_charge[:charge_model],
            ),
          )

          tax_codes = payload_charge.delete(:tax_codes)
          if tax_codes
            taxes_result = Charges::ApplyTaxesService.call(charge:, tax_codes:)
            taxes_result.raise_if_error!
          end

          # NOTE: charges cannot be edited if plan is attached to a subscription
          unless plan.attached_to_subscriptions?
            invoiceable = payload_charge.delete(:invoiceable)
            min_amount_cents = payload_charge.delete(:min_amount_cents)

            charge.invoiceable = invoiceable if License.premium? && !invoiceable.nil?
            charge.min_amount_cents = min_amount_cents || 0 if License.premium?

            charge.update!(payload_charge)
            charge
          end

          next
        end

        created_charge = create_charge(plan, payload_charge)
        created_charges_ids.push(created_charge.id)
      end

      # NOTE: Delete charges that are no more linked to the plan
      sanitize_charges(plan, hash_charges, created_charges_ids)
    end

    def sanitize_charges(plan, args_charges, created_charges_ids)
      args_charges_ids = args_charges.map { |c| c[:id] }.compact
      charges_ids = plan.charges.pluck(:id) - args_charges_ids - created_charges_ids
      plan.charges.where(id: charges_ids).find_each { |charge| discard_charge!(charge) }
    end

    def discard_charge!(charge)
      draft_invoice_ids = Invoice.draft.joins(plans: [:charges])
        .where(charges: { id: charge.id }).distinct.pluck(:id)

      charge.discard!
      charge.group_properties.discard_all

      Invoice.where(id: draft_invoice_ids).update_all(ready_to_be_refreshed: true) # rubocop:disable Rails/SkipsModelValidations
    end

    def process_charge_groups(plan, params_charge_groups, params_charges)
      created_charge_groups_ids = []

      hash_charge_groups = params_charge_groups.map { |c| c.to_h.deep_symbolize_keys }
      hash_charge_groups.each do |payload_charge_group|
        update_individual_charge_group(plan, payload_charge_group, params_charges, created_charge_groups_ids)
      end

      process_charges(plan, params_charges)

      # NOTE: Delete charge groups that are no more linked to the plan
      sanitize_charge_groups(plan, hash_charge_groups, created_charge_groups_ids)
    end

    def update_individual_charge_group(plan, payload_charge_group, params_charges, created_charge_groups_ids)
      charge_group = plan.charge_groups.find_by(id: payload_charge_group[:id])

      if charge_group
        properties = payload_charge_group.delete(:properties)
        charge_group.update!(
          invoice_display_name: payload_charge_group[:invoice_display_name],
          properties: properties.presence || ChargeGroups::BuildDefaultPropertiesService.call,
        )

        # NOTE: charge groups cannot be edited if plan is attached to a subscription
        unless plan.attached_to_subscriptions?
          invoiceable = payload_charge_group.delete(:invoiceable)
          min_amount_cents = payload_charge_group.delete(:min_amount_cents)

          charge_group.invoiceable = invoiceable if License.premium? && !invoiceable.nil?
          charge_group.min_amount_cents = min_amount_cents || 0 if License.premium?

          charge_group.update!(payload_charge_group)
          charge_group
        end

        return
      end

      created_charge_group = create_charge_group(plan, payload_charge_group)
      created_charge_groups_ids.push(created_charge_group.id)

      # NOTE: Update charge_group_id for child charges if their linked charge_group is created
      params_charges.select { |c| c[:charge_group_id] == payload_charge_group[:id] }.each do |charge|
        charge[:charge_group_id] = created_charge_group.id
      end
    end

    def create_charge_group(plan, params)
      charge_group = plan.charge_groups.new(
        invoice_display_name: params[:invoice_display_name],
        # NOTE: charge group is pay in advance by default since pay in arrears is not implemented yet
        pay_in_advance: params[:pay_in_advance] || true,
        properties: params[:properties].presence || ChargeGroups::BuildDefaultPropertiesService.call,
        invoiceable: params[:invoiceable] || true,
        min_amount_cents: params[:min_amount_cents] || 0,
      )

      charge_group.save!
      charge_group
    end

    def sanitize_charge_groups(plan, args_charge_groups, created_charge_groups_ids)
      args_charge_groups_ids = args_charge_groups.map { |c| c[:id] }.compact
      charge_groups_ids = plan.charge_groups.pluck(:id) - args_charge_groups_ids - created_charge_groups_ids
      plan.charge_groups.where(id: charge_groups_ids).find_each { |charge_group| discard_charge_group!(charge_group) }
    end

    def discard_charge_group!(charge_group)
      charge_group.charges.each { |charge| discard_charge!(charge) }
      charge_group.discard!
    end
  end
end
