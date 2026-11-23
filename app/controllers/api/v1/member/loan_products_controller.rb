module Api
  module V1
    module Member
      class LoanProductsController < ApplicationController
        before_action :authorize_request

        EQUITY_MULTIPLIER = 5

        def index
          products = ::LoanProduct
            .where(is_active: true)
            .where.not(id: blocked_loan_product_ids)
            .order(:priority)

          equity = member_equity_balance
          equity_limit = equity * EQUITY_MULTIPLIER
          outstanding = outstanding_non_entry_point_balance
          available_limit = [equity_limit - outstanding, 0].max

          render json: {
            data: products.map { |p|
              if p.is_entry_point?
                effective_min = p.min_loan_amount
                effective_max = p.max_loan_amount
              else
                effective_min = equity              # ← NEW: min = raw equity balance (1x), fully replaces product's configured min
                effective_max = [p.max_loan_amount, available_limit].min
              end

              {
                id: p.id,
                name: p.name,
                min_loan_amount: effective_min,
                max_loan_amount: effective_max,
                denomination: p.denomination,
                monthly_interest_rate: p.monthly_interest_rate,
                is_entry_point: p.is_entry_point
              }
            },
            equity_credit: {
              equity_balance: equity,
              equity_limit: equity_limit,
              outstanding_balance: outstanding,
              available_limit: available_limit
            }
          }
        end

        private

        def member_equity_balance
          MemberAccount
            .where(member_id: current_member.id, account_type: 'EQUITY', account_subtype: 'Share Capital', status: 'active')
            .sum(:balance)
        end

        def outstanding_non_entry_point_balance
          non_entry_point_ids = ::LoanProduct.where(is_entry_point: false).pluck(:id)

          current_member.loans
            .where(status: 'active', loan_product_id: non_entry_point_ids)
            .sum('principal_balance + interest_balance')
        end

        def blocked_loan_product_ids
          blocked = []

          active_loans = current_member.loans.where(status: 'active')
          active_loans.each do |loan|
            unpaid_count = AmortizationScheduleEntry
              .where(loan_id: loan.id, is_paid: false)
              .count
            blocked << loan.loan_product_id if unpaid_count <= 5
          end

          pending_product_ids = LoanApplication
            .where(member_id: current_member.id)
            .where.not(status: 'approved')
            .pluck(:loan_product_id)
          blocked.concat(pending_product_ids)

          unless has_active_entry_point_loan?
            non_entry_point_ids = ::LoanProduct.where(is_entry_point: false).pluck(:id)
            blocked.concat(non_entry_point_ids)
          end

          blocked.uniq
        end

        def has_active_entry_point_loan?
          entry_point_ids = ::LoanProduct.where(is_entry_point: true).pluck(:id)
          current_member.loans.where(status: 'active', loan_product_id: entry_point_ids).exists?
        end
      end
    end
  end
end
