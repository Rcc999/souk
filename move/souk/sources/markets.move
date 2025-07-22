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
