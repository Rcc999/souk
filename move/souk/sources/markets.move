module souk::markets {

    use std::type_name::TypeName;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Clock};
    use sui::tx_context::{TxContext};
    use souk::utils;
    use souk::marketplace;

    use souk::ownership::SoukOwnerCap;

    const EInsufficientMarketBalance: u64 = 0;
    const ETicketNotFoundInMarket: u64 = 1;

    const LIQUIDATION_THRESHOLD: u64 = 60_000_000; // 60% LTV in basis points
    const APR_DELTA_THRESHOLD: u64 = 100_000; // 0.1% threshold for APR updates

    public struct MarketKey has copy, drop, store {
        nft_type: TypeName,
        coin_type: TypeName,
    }

    public struct Market<phantom T, phantom C> has key, store {
        id: UID,
        borrowing_tickets: vector<ID>,
        lending_tickets: vector<ID>,
        treasury: Balance<C>,
        max_ltv: u64,
        optimal_utilisation_rate: u64,
        utilisation_rate: u64,
        base_variable_borrow_rate: u64,
        variable_rate_slope1: u64,
        variable_rate_slope2: u64,
        total_borrowed: u64,
        total_supplied: u64,
        current_apr: u64,
        last_updated_apr: u64,
    }

    public fun create_market_key<T, C>() : (MarketKey) {
        MarketKey {
            nft_type: std::type_name::get<T>(),
            coin_type: std::type_name::get<C>(),
        }
    }

    public fun create_market<T, C>(_soc: &mut SoukOwnerCap, ctx: &mut TxContext): ID {

        let market = Market<T, C> {
            id: object::new(ctx),
            borrowing_tickets: vector::empty<ID>(),
            lending_tickets: vector::empty<ID>(),
            treasury: balance::zero<C>(),
            max_ltv: 0,
            optimal_utilisation_rate: 80_000_000,
            utilisation_rate: 0,
            base_variable_borrow_rate: 2_000_000,
            variable_rate_slope1: 4_000_000,
            variable_rate_slope2: 60_000_000,
            total_borrowed: 0,
            total_supplied: 0,
            current_apr: 2_000_000,
            last_updated_apr: 0,
        };

        let market_id = market.id.to_inner();

        transfer::share_object(market);
        
        market_id
    }

    public entry fun update_market_max_ltv<T: key + store, C>(
        _soc: &mut SoukOwnerCap,
        market: &mut Market<T, C>,
        new_max_ltv: u64,
        ) {
            market.max_ltv = new_max_ltv;
        }

    public fun transfer_from_market_to_user<T: key + store, C>(
        market: &mut Market<T, C>,
        amount_to_borrow: u64,
        ctx: &mut TxContext
    ) : (Coin<C>)
    {
        assert!(market.treasury.value() >= amount_to_borrow, EInsufficientMarketBalance);

        let payment_balance = market.treasury.split(amount_to_borrow);
        payment_balance.into_coin(ctx)
    }

    public fun add_borrowing_ticket<T: key + store, C>(market: &mut Market<T, C>, ticket_id: ID) {
        vector::push_back(&mut market.borrowing_tickets, ticket_id);
    }

    public fun add_lending_ticket<T: key + store, C>(market: &mut Market<T, C>, ticket_id: ID) {
        vector::push_back(&mut market.lending_tickets, ticket_id);
    }

    public fun add_to_balance<T, C>(market: &mut Market<T, C>, payment: Coin<C>) {
        coin::put(&mut market.treasury, payment);
    }

    public fun get_tickets_ids<T, C>(market: &Market<T, C>) : (&vector<ID>, &vector<ID>) {
        (&market.borrowing_tickets, &market.lending_tickets)
    }

    public fun get_max_ltv<T, C>(market: &Market<T, C>): u64 {
        market.max_ltv
    }

    public fun get_total_borrowed<T, C>(market: &Market<T, C>): u64 {
        market.total_borrowed
    }

    public fun get_total_supplied<T, C>(market: &Market<T, C>): u64 {
        market.total_supplied
    }

    public fun get_treasury_value<T, C>(market: &Market<T, C>): u64 {
        market.treasury.value()
    }

    public fun update_total_borrowed<T, C>(market: &mut Market<T, C>, new_total: u64) {
        market.total_borrowed = new_total;
    }

    public fun update_total_supplied<T, C>(market: &mut Market<T, C>, new_total: u64) {
        market.total_supplied = new_total;
    }

    public fun get_liquidation_threshold(): u64 {
        LIQUIDATION_THRESHOLD
    }

    public fun get_apr_delta_threshold(): u64 {
        APR_DELTA_THRESHOLD
    }

    public fun get_optimal_utilisation_rate<T, C>(market: &Market<T, C>): u64 {
        market.optimal_utilisation_rate
    }

    public fun get_base_variable_borrow_rate<T, C>(market: &Market<T, C>): u64 {
        market.base_variable_borrow_rate
    }

    public fun get_variable_rate_slope1<T, C>(market: &Market<T, C>): u64 {
        market.variable_rate_slope1
    }

    public fun get_variable_rate_slope2<T, C>(market: &Market<T, C>): u64 {
        market.variable_rate_slope2
    }

    public fun get_current_apr<T, C>(market: &Market<T, C>): u64 {
        market.current_apr
    }

    public fun get_last_updated_apr<T, C>(market: &Market<T, C>): u64 {
        market.last_updated_apr
    }

    public fun update_last_updated_apr<T, C>(market: &mut Market<T, C>, new_timestamp: u64) {
        market.last_updated_apr = new_timestamp;
    }

    public fun get_borrowing_tickets<T, C>(market: &Market<T, C>): &vector<ID> {
    &market.borrowing_tickets
    }

    public fun get_lending_tickets<T, C>(market: &Market<T, C>): &vector<ID> {
    &market.lending_tickets
    }

    public fun set_current_apr<T, C>(market: &mut Market<T, C>, value: u64) {
    market.current_apr = value;
    }

    public fun set_last_updated_apr<T, C>(market: &mut Market<T, C>, value: u64) {
        market.last_updated_apr = value;
    }
    
    public fun set_utilisation_rate<T, C>(market: &mut Market<T, C>, value: u64) {
        market.utilisation_rate = value;
    }

    public fun remove_borrowing_ticket<T, C>(market: &mut Market<T, C>, ticket_id: ID) {
        
        let len = vector::length(&market.borrowing_tickets);
        let mut i = 0;
        while (i < len) {
            if (vector::borrow(&market.borrowing_tickets, i) == ticket_id) {
                vector::swap_remove(&mut market.borrowing_tickets, i);
                return
            };
            i = i + 1;
        };

        assert!(0==1, ETicketNotFoundInMarket);
    }

    public fun remove_lending_ticket<T, C>(market: &mut Market<T, C>, ticket_id: ID) {
        let len = vector::length(&market.lending_tickets);
        let mut i = 0;
        while (i < len) {
            if (vector::borrow(&market.lending_tickets, i) == ticket_id) {
                vector::swap_remove(&mut market.lending_tickets, i);
                return
            };
            i = i + 1;
        };

        assert!(0==1, ETicketNotFoundInMarket);
    }


}
