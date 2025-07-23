module souk::marketplace {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::coin::Coin;
    use sui::sui::SUI;
    use sui::transfer_policy::{Self, TransferPolicy};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
     use sui::clock::{Clock};
    use souk::markets::{Self, Market, MarketKey};
    use souk::tickets::{Basket, BorrowingTicket, LendingTicket, BorrowingPosition, LendingPosition};
    use souk::ownership::SoukOwnerCap;
    use sui::tx_context::{TxContext, sender};
    use souk::markets::LIQUIDATION_THRESHOLD;
    use souk::tickets;


    const EPaymentDifferentFromMinPrice: u64 = 0;
    const EPaymentDifferentFromSupplied: u64 = 1;
    const EDebtNotCleared: u64 = 2;
    const EFeesNotClaimed: u64 = 3;
    const EPositionNotFound: u64 = 4;

    public struct SoukMarketPlace has key {
        id: UID,
        souk_kiosk: Kiosk,
        souk_kiosk_cap: KioskOwnerCap,
        market_keys: vector<MarketKey>,
        market_registry: Table<MarketKey, ID>,
        borrowing_positions: Table<ID, BorrowingPosition>,
        lending_positions: Table<ID, LendingPosition>,
        to_liquidate : VecSet<ID>
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

        vector::push_back(&mut souk_marketplace.market_keys, key);
    }

    public entry fun borrow<T: key + store, C>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_borrow: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let ticket_id = tickets::get_borrowing_ticket_id(ticket);
        assert!(marketplace.borrowing_positions.contains(ticket_id), EPositionNotFound);
        let borrowing_position = marketplace.borrowing_positions.borrow_mut(ticket_id);
        let market_max_ltv = markets::get_max_ltv(market);

        tickets::update_borrow_ticket(borrowing_position, market_max_ltv, amount_to_borrow, 0);

        let (_, _, ltv, _, _, _) = tickets::get_borrowing_position_info(borrowing_position);
        if (ltv > markets::get_liquidation_threshold()) {
            marketplace.to_liquidate.insert(ticket_id);
        };

        let total_borrowed = markets::get_total_borrowed(market) + amount_to_borrow;
        markets::update_total_borrowed(market, total_borrowed);
        let treasury_value = markets::get_treasury_value(market);
        markets::update_total_supplied(market, treasury_value);

        let payment_to_transfer = markets::transfer_from_market_to_user<T, C>(market, amount_to_borrow, ctx);
        transfer::public_transfer(payment_to_transfer, ctx.sender());

        update_apr(market, marketplace, clock);
    }

    public entry fun repay<T: key + store, C>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_repay: u64,
        payment: Coin<C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let supplied = payment.balance().value();
        assert!(supplied == amount_to_repay, EPaymentDifferentFromSupplied);
        let ticket_id = tickets::get_borrowing_ticket_id(ticket);
        assert!(marketplace.borrowing_positions.contains(ticket_id), EPositionNotFound);
        let borrowing_position = marketplace.borrowing_positions.borrow_mut(ticket_id);
        let market_max_ltv = markets::get_max_ltv(market);

        tickets::update_borrow_ticket(borrowing_position, market_max_ltv, 0, amount_to_repay);

        let new_total_borrowed = if (markets::get_total_borrowed(market) >= amount_to_repay) {
            markets::get_total_borrowed(market) - amount_to_repay
        } else {
            0
        };
        markets::update_total_borrowed(market, new_total_borrowed);
        markets::add_to_balance<T, C>(market, payment);
        let treasury_value = markets::get_treasury_value(market);
        markets::update_total_supplied(market, treasury_value);
        update_apr(market, marketplace, clock);
    }

    
    
    public entry fun lend<T: key + store, C>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        lender_basket: &mut Basket,
        amount: u64,
        payment: Coin<C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let supplied = payment.balance().value();
        assert!(supplied == amount, EPaymentDifferentFromSupplied);
        markets::add_to_balance<T, C>(market, payment);
        let (ticket_id, ticket, position) = tickets::create_lending_ticket<T, C>(lender_basket, supplied, ctx);
        assert!(!marketplace.lending_positions.contains(ticket_id), EPositionNotFound);
        marketplace.lending_positions.add(ticket_id, position);
        transfer::public_transfer(ticket, ctx.sender());
        markets::add_lending_ticket<T, C>(market, ticket_id);

        let treasury_value = markets::get_treasury_value(market);
        markets::update_total_supplied(market, treasury_value);
        update_apr(market, marketplace, clock);
    }

    public entry fun withdraw_lending<T: key + store, C: key + store>(
        ticket: LendingTicket<T, C>,
        marketplace: &mut SoukMarketPlace,
        lender_basket: &mut Basket,
        market: &mut Market<T, C>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let ticket_id = tickets::get_lending_ticket_id(&ticket);
        assert!(marketplace.lending_positions.contains(ticket_id), EPositionNotFound);
        let lending_position = marketplace.lending_positions.remove(ticket_id);
        let (_, _, amount_supplied, to_claim, _) = tickets::get_lending_position_info(&lending_position);
        assert!(to_claim == 0, EFeesNotClaimed);

        let payment_to_transfer = markets::transfer_from_market_to_user<T, C>(market, amount_supplied, ctx);
        transfer::public_transfer(payment_to_transfer, ctx.sender());
        tickets::burn_lending_position(lending_position);
        tickets::remove_lending_ticket(lender_basket, ticket);
        markets::remove_lending_ticket(market, ticket_id);

        let treasury_value = markets::get_treasury_value(market);
        markets::update_total_supplied(market, treasury_value);
        update_apr(market, marketplace, clock);
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
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let ticket_id = tickets::get_borrowing_ticket_id(&ticket);
        assert!(marketplace.borrowing_positions.contains(ticket_id), EPositionNotFound);
        let borrowing_position = marketplace.borrowing_positions.remove(ticket_id);
        let (_, _, _, _, debt, _) = tickets::get_borrowing_position_info(&borrowing_position);
        assert!(debt == 0, EDebtNotCleared);

        let nft_id = tickets::get_nft_id(&ticket);
        let nft_min_price = tickets::get_nft_min_price(&ticket);
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

        tickets::burn_borrowing_position(borrowing_position);
        tickets::remove_borrowing_ticket(borrower_basket, ticket);
        markets::remove_borrowing_ticket(market, ticket_id);

        let treasury_value = markets::get_treasury_value(market);
        markets::update_total_supplied(market, treasury_value);
        update_apr(market, marketplace, clock);
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
        clock: &Clock,
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

        let (ticket_id, ticket, position) = tickets::create_borrowing_ticket<T, C>(borrower_basket, nft_id, nft_min_price, nft_value, ctx);
        assert!(!marketplace.borrowing_positions.contains(ticket_id), EPositionNotFound);
        marketplace.borrowing_positions.add(ticket_id, position);
        transfer::public_transfer(ticket, ctx.sender());
        markets::add_borrowing_ticket<T, C>(market, ticket_id);

        let treasury_value = markets::get_treasury_value(market);
        markets::update_total_supplied(market, treasury_value);
        update_apr(market, marketplace, clock);
    }

    
    public entry fun update_borrowing_ticket_collateral_value<T: key + store, C>(
        _soc: &mut SoukOwnerCap,
        marketplace: &mut SoukMarketPlace,
        ticket_id: ID,
        new_collateral_value: u64,
        market: &mut Market<T, C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(marketplace.borrowing_positions.contains(ticket_id), EPositionNotFound);
        let position = marketplace.borrowing_positions.borrow_mut(ticket_id);
        tickets::update_borrowing_position_collateral_value(position, new_collateral_value);

        let (_, _, ltv, _, _, _) = tickets::get_borrowing_position_info(position);
        if (ltv > markets::get_liquidation_threshold()) {
            marketplace.to_liquidate.insert(ticket_id);
        };
        update_apr(market, marketplace, clock);
    }

    public entry fun update_multiple_borrowing_tickets_collateral_value<T: key + store, C>(
        _soc: &mut SoukOwnerCap,
        marketplace: &mut SoukMarketPlace,
        ticket_ids: vector<ID>,
        new_collateral_values: vector<u64>,
        market: &mut Market<T, C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let len = vector::length(&ticket_ids);
        let val_len = vector::length(&new_collateral_values);
        assert!(len == val_len, 1);
        let mut i = 0;
        while (i < len) {
            let ticket_id = *vector::borrow(&ticket_ids, i);
            assert!(marketplace.borrowing_positions.contains(ticket_id), EPositionNotFound);
            let position = marketplace.borrowing_positions.borrow_mut(ticket_id);
            let new_value = *vector::borrow(&new_collateral_values, i);
            tickets::update_borrowing_position_collateral_value(position, new_value);

            let (_, _, ltv, _, _, _) = tickets::get_borrowing_position_info(position);
            if (ltv > markets::get_liquidation_threshold()) {
                marketplace.to_liquidate.insert(ticket_id);
            };
            i = i + 1;
        };
        update_apr(market, marketplace, clock);
    }

    public fun update_apr<T: key + store, C>(
        market: &mut Market<T, C>,
        marketplace: &mut SoukMarketPlace,
        clock: &Clock,
    ) {
        let utilisation_rate = souk::utils::compute_utilisation_rate(
            markets::get_total_borrowed(market),
            markets::get_total_supplied(market)
        );
        let new_apr = souk::utils::calculate_variable_interest_rate(
            utilisation_rate,
            markets::get_optimal_utilisation_rate(market),
            markets::get_base_variable_borrow_rate(market),
            markets::get_variable_rate_slope1(market),
            markets::get_variable_rate_slope2(market),
        );

        let apr_diff = if (new_apr > markets::get_current_apr(market)) {
            new_apr - markets::get_current_apr(market)
        } else {
            markets::get_current_apr(market) - new_apr
        };

        if (apr_diff > markets::get_apr_delta_threshold()) {
            let current_timestamp = clock.timestamp_ms();
            let time_elapsed = current_timestamp - markets::get_last_updated_apr(market);
        
            let mut i = 0;
            let borrowing_tickets = markets::get_borrowing_tickets(market);
            let len = vector::length(borrowing_tickets);
            while (i < len) {
                let ticket_id = *vector::borrow(borrowing_tickets, i);
                let position = marketplace.borrowing_positions.borrow_mut(ticket_id);
                let interest = souk::utils::calculate_accrued_interest(
                    tickets::get_borrowed(position),
                    markets::get_current_apr(market),
                    time_elapsed,
                );
                tickets::add_to_debt(position, interest);

                let (_, _, ltv, _, _, _) = tickets::get_borrowing_position_info(position);
                if (ltv > markets::get_liquidation_threshold()) {
                    marketplace.to_liquidate.insert(ticket_id);
                };
                i = i + 1;
            };
            i = 0;
            let lending_tickets = markets::get_lending_tickets(market);
            let len = vector::length(lending_tickets);
            while (i < len) {
                let ticket_id = *vector::borrow(lending_tickets, i);
                let position = marketplace.lending_positions.borrow_mut(ticket_id);
                let interest = souk::utils::calculate_accrued_interest(
                    tickets::get_amount_supplied(position),
                    markets::get_current_apr(market),
                    time_elapsed,
                );
                tickets::add_to_claim(position, interest);
                i = i + 1;
            };
            markets::set_current_apr(market, new_apr);
            markets::set_last_updated_apr(market, current_timestamp);
            markets::set_utilisation_rate(market, utilisation_rate);
        };
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
            to_liquidate: vec_set::empty()
        };

        transfer::share_object(souk_market_place);

    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init(ctx)
    }
}