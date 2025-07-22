module souk::marketplace {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::coin::Coin;
    use sui::sui::SUI;
    use sui::transfer_policy::{Self, TransferPolicy};
    use sui::table::{Self, Table};

    use souk::markets::{Market, MarketKey};
    use souk::tickets::{Basket, BorrowingTicket, LendingTicket, BorrowingPosition, LendingPosition};

    use souk::ownership::SoukOwnerCap;
    use souk::markets;

    const EPaymentDifferentFromMinPrice: u64 = 0;
    const EPaymentDifferentFromSupplied: u64 = 1;
    const EDebtNotCleared: u64 = 2;
    const EFeesNotClaimed: u64 = 3;

    public struct SoukMarketPlace has key {
        id: UID,
        souk_kiosk: Kiosk,
        souk_kiosk_cap: KioskOwnerCap,
        market_keys: vector<MarketKey>,
        market_registry: Table<MarketKey, ID>,
        borrowing_positions: Table<ID, BorrowingPosition>,
        lending_positions: Table<ID, LendingPosition>
    }

    public fun get_market_id<T, C>(souk_marketplace: &SoukMarketPlace): &ID {
        let key = souk::markets::create_market_key<T, C>();
        table::borrow(&souk_marketplace.market_registry, key)
    }

    public entry fun register_market<T: key + store, C>(
        soc: &mut SoukOwnerCap,
        souk_marketplace: &mut SoukMarketPlace,
        ctx: &mut TxContext
    ) {

        let market_id = souk::markets::create_market<T, C>(soc, ctx);

        let key = souk::markets::create_market_key<T, C>();

        table::add(&mut souk_marketplace.market_registry, key, market_id);
    }

    public entry fun borrow<T: key + store, C>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_borrow: u64,
        ctx: &mut TxContext
    ) {

        let ticket_id = souk::tickets::get_borrowing_ticket_id(ticket);
        let borrowing_position = marketplace.borrowing_positions.borrow_mut(ticket_id);
        let market_max_ltv = markets::get_max_ltv(market);
        souk::tickets::update_borrow_ticket(borrowing_position, market_max_ltv, amount_to_borrow, 0);
        let payment_to_transfer = souk::markets::transfer_from_market_to_user<T, C>(market, amount_to_borrow, ctx);
        transfer::public_transfer(payment_to_transfer, ctx.sender());
    }

    public entry fun repay<T: key + store, C>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_repay: u64,
        payment: Coin<C>,
        ctx: &mut TxContext
    ) {
        let supplied = payment.balance().value();
        assert!(supplied == amount_to_repay, EPaymentDifferentFromSupplied);
        let ticket_id = souk::tickets::get_borrowing_ticket_id(ticket);
        let borrowing_position = marketplace.borrowing_positions.borrow_mut(ticket_id);
        let market_max_ltv = markets::get_max_ltv(market);
        souk::tickets::update_borrow_ticket(borrowing_position, market_max_ltv, 0, amount_to_repay);
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
        nft_value: u64,
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

        let (ticket_id, ticket, position) = souk::tickets::create_borrowing_ticket<T, C>(borrower_basket, nft_id, nft_min_price, nft_value, ctx);
        assert!(!marketplace.borrowing_positions.contains(ticket_id), 1);
        marketplace.borrowing_positions.add(ticket_id, position);
        transfer::public_transfer(ticket, ctx.sender());
        souk::markets::add_borrowing_ticket<T, C>(market, ticket_id);

    }
    
    public entry fun lend<T: key + store, C>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        lender_basket: &mut Basket,
        amount: u64,
        payment: Coin<C>,
        ctx: &mut TxContext
    ) {
        let supplied = payment.balance().value();

        assert!(supplied == amount, EPaymentDifferentFromSupplied);
        souk::markets::add_to_balance<T, C>(market, payment);

        let (ticket_id, ticket, position) = souk::tickets::create_lending_ticket<T, C>( lender_basket, supplied, ctx);
        assert!(!marketplace.lending_positions.contains(ticket_id), 1);
        marketplace.lending_positions.add(ticket_id, position);
        transfer::public_transfer(ticket, ctx.sender());
        souk::markets::add_lending_ticket<T, C>(market, ticket_id);
    }

    public entry fun withdraw_lending<T: key + store, C: key + store>(
        ticket: LendingTicket<T, C>,
        marketplace: &mut SoukMarketPlace,
        lender_basket: &mut Basket,
        market: &mut Market<T, C>,
        ctx: &mut TxContext,
    ) {
        let ticket_id = souk::tickets::get_lending_ticket_id(&ticket);
        let lending_position = marketplace.lending_positions.remove(ticket_id);
        let (_, _, amount_supplied, to_claim, _) = souk::tickets::get_lending_position_info(&lending_position);
        assert!(to_claim == 0, EFeesNotClaimed);
        let payment_to_transfer = souk::markets::transfer_from_market_to_user<T, C>(market, amount_supplied, ctx);
        transfer::public_transfer(payment_to_transfer, ctx.sender());
        souk::tickets::burn_lending_position(lending_position);
        souk::tickets::remove_lending_ticket(lender_basket, ticket);
        souk::markets::remove_lending_ticket(market, ticket_id)
    }

    
    public entry fun withdraw_nft<T: key + store, C: key + store>(
        ticket: BorrowingTicket<T, C>,
        policy: &TransferPolicy<T>,
        marketplace: &mut SoukMarketPlace,
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        borrower_basket: &mut Basket,
        market: &mut Market<T, C>,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {

        let ticket_id = souk::tickets::get_borrowing_ticket_id(&ticket);
        let borrowing_position = marketplace.borrowing_positions.remove(ticket_id);
        let (_, _, _, _, debt) = souk::tickets::get_borrowing_position_info(&borrowing_position);
        
        assert!(debt == 0, EDebtNotCleared);

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

        souk::tickets::burn_borrowing_position(borrowing_position);
        souk::tickets::remove_borrowing_ticket(borrower_basket, ticket);
        souk::markets::remove_borrowing_ticket(market, ticket_id)

    }

    
    public entry fun update_borrowing_ticket_collateral_value(
        _soc: &mut SoukOwnerCap,
        marketplace: &mut SoukMarketPlace,
        ticket_id: ID,
        new_collateral_value: u64,
        ctx: &mut TxContext
    ) {
        assert!(marketplace.borrowing_positions.contains(ticket_id), 0);
        let position = marketplace.borrowing_positions.borrow_mut(ticket_id);
        souk::tickets::update_borrowing_position_collateral_value(position, new_collateral_value);
    }

    public entry fun update_multiple_borrowing_tickets_collateral_value(
        _soc: &mut SoukOwnerCap,
        marketplace: &mut SoukMarketPlace,
        ticket_ids: vector<ID>,
        new_collateral_values: vector<u64>,
        ctx: &mut TxContext
    ) {
        let len = vector::length<ID>(&ticket_ids);
        let val_len = vector::length<u64>(&new_collateral_values);
        assert!(len == val_len, 1); // Error code 1: mismatched lengths

        let mut i = 0;
        while (i < len) {
            let ticket_id = *vector::borrow<ID>(&ticket_ids, i);
            assert!(marketplace.borrowing_positions.contains(ticket_id), 2); // Error code 2: ticket not found

            let position = marketplace.borrowing_positions.borrow_mut(ticket_id);
            let new_value = *vector::borrow<u64>(&new_collateral_values, i);
            souk::tickets::update_borrowing_position_collateral_value(position, new_value);

            i = i + 1;
        }
    }


    fun init(ctx: &mut TxContext) {
        let (kiosk, cap) = kiosk::new(ctx);

        let souk_market_place = SoukMarketPlace {
            id: object::new(ctx),
            souk_kiosk: kiosk,
            souk_kiosk_cap: cap,
            market_keys: vector::empty<MarketKey>(),
            market_registry: table::new<MarketKey, ID>(ctx),
            borrowing_positions: table::new<ID, BorrowingPosition>(ctx),
            lending_positions: table::new<ID, LendingPosition>(ctx),
        };

        transfer::share_object(souk_market_place);

    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init(ctx)
    }
}