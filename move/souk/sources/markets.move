module souk::markets {

    use std::type_name::TypeName;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};

    use souk::ownership::SoukOwnerCap;

    const EInsufficientMarketBalance: u64 = 0;

    public struct MarketKey has copy, drop, store {
        nft_type: TypeName,
        coin_type: TypeName,
    }

    public struct Market<phantom T, phantom C> has key, store {
        id: UID,
        borrowing_tickets: vector<ID>,
        lending_tickets: vector<ID>,
        treasury: Balance<C>,
    }

    public fun create_market_key<T, C>() : (MarketKey) {
        MarketKey {
            nft_type: std::type_name::get<T>(),
            coin_type: std::type_name::get<C>(),
        }
    }

    public fun create_market<T, C>(soc: SoukOwnerCap, ctx: &mut TxContext): (ID, SoukOwnerCap) {

        let market = Market<T, C> {
            id: object::new(ctx),
            borrowing_tickets: vector::empty<ID>(),
            lending_tickets: vector::empty<ID>(),
            treasury: balance::zero<C>(),
        };

        let market_id = market.id.to_inner();

        transfer::share_object(market);
        
        (market_id, soc)
    }

    #[allow(lint(self_transfer))]
    public fun transfer_from_market_to_user<T: key + store, C>(
        market: &mut Market<T, C>,
        amount_to_borrow: u64,
        ctx: &mut TxContext
    )
    {
        assert!(market.treasury.value() >= amount_to_borrow, EInsufficientMarketBalance);

        let payment_balance = market.treasury.split(amount_to_borrow);
        let payment = payment_balance.into_coin(ctx);

        transfer::public_transfer(payment, ctx.sender());
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

}
