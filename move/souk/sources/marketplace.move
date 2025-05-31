module souk::marketplace {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::coin::Coin;
    use sui::sui::SUI;
    use sui::transfer_policy::{Self, TransferPolicy};
    use sui::table::{Self, Table};

    use souk::markets::{Market, MarketKey};
    use souk::tickets::{Basket, BorrowingTicket};

    use souk::ownership::SoukOwnerCap;

    const EPaymentDifferentFromMinPrice: u64 = 0;
    const EPaymentDifferentFromSupplied: u64 = 1;

    public struct SoukMarketPlace has key {
        id: UID,
        souk_kiosk: Kiosk,
        souk_kiosk_cap: KioskOwnerCap,
        market_keys: vector<MarketKey>,
        market_registry: Table<MarketKey, ID>
    }

    public fun get_market_id<T, C>(souk_marketplace: &SoukMarketPlace): &ID {
        let key = souk::markets::create_market_key<T, C>();

        table::borrow(&souk_marketplace.market_registry, key)
    }

    public entry fun register_market<T: key + store, C>(
        soc: SoukOwnerCap,
        souk_marketplace: &mut SoukMarketPlace,
        ctx: &mut TxContext
    ) {

        let (market_id, soc) = souk::markets::create_market<T, C>(soc, ctx);

        let key = souk::markets::create_market_key<T, C>();

        table::add(&mut souk_marketplace.market_registry, key, market_id);

        transfer::public_transfer(soc, ctx.sender());
    }

    public entry fun borrow<T: key + store, C>(
        market: &mut Market<T, C>,
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_borrow: u64,
        ctx: &mut TxContext
    ) {
        souk::tickets::update_borrow_ticket<T, C>(ticket, amount_to_borrow, 0, ctx.epoch_timestamp_ms());
        souk::markets::transfer_from_market_to_user<T, C>(market, amount_to_borrow, ctx);
    }

    public entry fun repay<T: key + store, C>(
        market: &mut Market<T, C>,
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_repay: u64,
        payment: Coin<C>,
        ctx: &mut TxContext
    ) {
        let supplied = payment.balance().value();
        assert!(supplied == amount_to_repay, EPaymentDifferentFromSupplied);
        souk::tickets::update_borrow_ticket<T, C>(ticket, 0, amount_to_repay, ctx.epoch_timestamp_ms());
        souk::markets::add_to_balance<T, C>(market, payment);
    }

    public entry fun transfer_nft<T: key + store>(
        nft_id: ID,
        nft_min_price: u64,
        from_kiosk: &mut Kiosk,
        from_kiosk_cap: &KioskOwnerCap,
        to_kiosk: &mut Kiosk,
        to_kiosk_cap: &KioskOwnerCap,
        policy: &TransferPolicy<T>,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {

        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            from_kiosk,
            from_kiosk_cap,
            nft_id,
            nft_min_price,
            ctx
        );

        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            from_kiosk,
            purchase_cap,
            payment
        );

        transfer_policy::confirm_request<T>(policy, transfer_req);

        kiosk::lock<T>(
            to_kiosk,
            to_kiosk_cap,
            policy,
            nft_object
        );
    }
    public entry fun provide_nft_as_collateral<T: key + store, C>(
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        borrower_basket: &mut Basket,
        nft_id: ID,
        nft_min_price: u64,
        policy: &TransferPolicy<T>,
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        payment: Coin<SUI>,
        ctx: &mut TxContext
        ) {

        let supplied = payment.balance().value();

        assert!(supplied == nft_min_price, EPaymentDifferentFromMinPrice);

        transfer_nft<T>(
            nft_id,
            nft_min_price,
            borrower_kiosk,
            borrower_kiosk_cap,
            &mut marketplace.souk_kiosk,
            &marketplace.souk_kiosk_cap,
            policy,
            payment,
            ctx
            );

        let ticket_id = souk::tickets::create_borrowing_ticket<T, C>(borrower_basket, nft_id, nft_min_price, ctx);
        souk::markets::add_borrowing_ticket<T, C>(market, ticket_id);

    }
    
    public entry fun lend<T: key + store, C>(
        market: &mut Market<T, C>,
        lender_basket: &mut Basket,
        amount: u64,
        payment: Coin<C>,
        ctx: &mut TxContext
    ) {
        let supplied = payment.balance().value();

        assert!(supplied == amount, EPaymentDifferentFromSupplied);
        souk::markets::add_to_balance<T, C>(market, payment);

        let ticket_id = souk::tickets::create_lending_ticket<T, C>( lender_basket, supplied, ctx);
        souk::markets::add_lending_ticket<T, C>(market, ticket_id);
    }

    
    //TODO: Ensure references in Markets, Baskets, etc. are correctly removed
    //TODO: Ensure the position is good.
    public entry fun withdraw_nft<T: key + store, C: key + store>(
        ticket: BorrowingTicket<T, C>,
        policy: &TransferPolicy<T>,
        marketplace: &mut SoukMarketPlace,
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        borrower_basket: &mut Basket,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {

        // TODO: Assert that all debt etc were repaid

        let nft_id = souk::tickets::get_nft_id(&ticket);
        let nft_min_price = souk::tickets::get_nft_min_price(&ticket);

        transfer_nft<T>(
            nft_id,
            nft_min_price,
            &mut marketplace.souk_kiosk,
            &marketplace.souk_kiosk_cap,
            borrower_kiosk,
            borrower_kiosk_cap,
            policy,
            payment,
            ctx
            );

        souk::tickets::remove_borrowing_ticket(borrower_basket, ticket);
    }
        

    fun init(ctx: &mut TxContext) {
        let (kiosk, cap) = kiosk::new(ctx);

        let table = table::new<MarketKey, ID>(ctx);

        let souk_market_place = SoukMarketPlace {
            id: object::new(ctx),
            souk_kiosk: kiosk,
            souk_kiosk_cap: cap,
            market_keys: vector::empty<MarketKey>(),
            market_registry: table,
        };

        transfer::share_object(souk_market_place);

    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init(ctx)
    }
}