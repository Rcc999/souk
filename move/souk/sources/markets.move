module souk::markets {

    use std::type_name::TypeName;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};

    use souk::ownership::SoukOwnerCap;

    const EInsufficientMarketBalance: u64 = 0;
    const ETicketNotFoundInMarket: u64 = 1;

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

        base_interest_rate: u64,        // Annual rate in basis points (e.g., 500 = 5%)
        ltv_multiplier: u64,            // LTV risk multiplier (e.g., 200 = 2x)
        utilization_multiplier: u64,    // Utilization multiplier (e.g., 100 = 1x)
        time_factor: u64,               // Daily time penalty in basis points (e.g., 1 = 0.01%)
        max_time_penalty: u64,          // Cap on time penalty (e.g., 500 = 5%)
        total_borrowed: u64,            // Track total borrowed amount
        total_supplied: u64,            // Track total supplied amount
    }

    public fun create_market_key<T, C>() : (MarketKey) {
        MarketKey {
            nft_type: std::type_name::get<T>(),
            coin_type: std::type_name::get<C>(),
        }
    }

    public fun create_market<T, C>(_soc: &mut SoukOwnerCap, ctx: &mut TxContext): ID {

        // TODO: Pass as arguments the params
        let market = Market<T, C> {
            id: object::new(ctx),
            borrowing_tickets: vector::empty<ID>(),
            lending_tickets: vector::empty<ID>(),
            treasury: balance::zero<C>(),
            max_ltv: 0,
            base_interest_rate: 0,
            ltv_multiplier: 0,
            utilization_multiplier: 0,
            time_factor: 0,
            max_time_penalty: 0,
            total_borrowed: 0,
            total_supplied: 0,
        };

        let market_id = market.id.to_inner();

        transfer::share_object(market);
        
        market_id
    }

    public fun get_market_info<T, C>(market: &mut Market<T, C>) : (
        ID, u64, u64, u64, u64, u64, u64, u64, u64
    ) {
        (
            market.id.to_inner(),
            market.max_ltv,
            market.base_interest_rate,
            market.ltv_multiplier,
            market.utilization_multiplier,
            market.time_factor,
            market.max_time_penalty,
            market.total_borrowed,
            market.total_supplied
        )
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

    // Get market utilization ratio
    public fun get_utilization_ratio<T, C>(market: &Market<T, C>): u64 {
        souk::utils::compute_utilization_ratio(market.total_borrowed, market.total_supplied)
    }

    // Update market totals when lending
    public fun add_to_total_supplied<T, C>(market: &mut Market<T, C>, amount: u64) {
        market.total_supplied = market.total_supplied + amount;
    }

    // Update market totals when borrowing
    public fun add_to_total_borrowed<T, C>(market: &mut Market<T, C>, amount: u64) {
        market.total_borrowed = market.total_borrowed + amount;
    }

    // Update market totals when repaying
    public fun subtract_from_total_borrowed<T, C>(market: &mut Market<T, C>, amount: u64) {
        market.total_borrowed = market.total_borrowed - amount;
    }

    // Update market totals when withdrawing lending
    public fun subtract_from_total_supplied<T, C>(market: &mut Market<T, C>, amount: u64) {
        market.total_supplied = market.total_supplied - amount;
    }

    // Admin function to set market parameters
    public entry fun set_market_interest_params<T, C>(
        _soc: &mut SoukOwnerCap,
        market: &mut Market<T, C>,
        base_rate: u64,
        ltv_multiplier: u64,
        utilization_multiplier: u64,
        time_factor: u64,
        max_time_penalty: u64
    ) {
        market.base_interest_rate = base_rate;
        market.ltv_multiplier = ltv_multiplier;
        market.utilization_multiplier = utilization_multiplier;
        market.time_factor = time_factor;
        market.max_time_penalty = max_time_penalty;
    }

}
