module souk::protocol {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
    use sui::balance::{Self, Balance};
    use sui::clock::timestamp_ms;

    public struct SoukMarketPlace has key {
        id: UID,
        souk_kiosk: Kiosk,
        souk_kiosk_cap: KioskOwnerCap,
        market_ids: vector<ID>
    }

    #[allow(unused_type_parameter)]
    public struct Market<T, C> has key, store {
        id: UID,
        borrowing_tickets: vector<ID>,
        lending_tickets: vector<ID>,
        treasury: Balance<C>,
        // ... Total supplied, total debt, etc. dynammic updated
    }

    public struct SoukOwnerCap has key, store {
        id: UID,
    }

    public struct Basket has key, store {
        id: UID,
        borrowing_tickets: vector<ID>,
        lending_tickets: vector<ID>,
        // ... Total supplied, total debt, etc. dynammic updated
    }

    #[allow(unused_type_parameter)]
    public struct BorrowingTicket<T, C> has key, store {
        id: UID,
        market_id: ID,
        
        nft: ID,
        min_price: u64,
        borrower_kiosk_id: ID,
        borrower_kiosk_cap_id: ID,
        transfer_policy_id: ID,

        max_ltv: u64,
        utilization_rate: u64,
        debt: u64,
        last_update_timestamp: u64
    }

    #[allow(unused_type_parameter)]
    public struct LendingTicket<T, C> has key, store {
        id: UID,
        market_id: ID,

        amount_supplied: u64,
        to_claim: u64,
        claimed: u64,
        last_update_timestamp: u64
    }



    public entry fun create_market<T: key + store, C: key + store>(
        souk_owner_cap: SoukOwnerCap,
        souk_marketplace: &mut SoukMarketPlace,
        ctx: &mut TxContext
    ) {

        let market = Market<T, C> {
            id: object::new(ctx),
            borrowing_tickets: vector::empty<ID>(),
            lending_tickets: vector::empty<ID>(),
            treasury: balance::zero<C>(),
        };
        
        vector::push_back(&mut souk_marketplace.market_ids, market.id.to_inner());

        transfer::transfer(market, ctx.sender());

        transfer::transfer(souk_owner_cap, ctx.sender());
    }

    public entry fun borrow<T: key + store, C: key + store>(
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        borrower_basket: &mut Basket,
        nft: ID,
        min_price: u64,
        policy: &TransferPolicy<T>,
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        payment: Coin<SUI>,
        ctx: &mut TxContext
        ) {
        
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft,
            min_price,
            ctx
        );

        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk,
            purchase_cap,
            payment
        );

        transfer_policy::confirm_request<T>(policy, transfer_req);

        kiosk::lock<T>(
            &mut marketplace.souk_kiosk,
            &marketplace.souk_kiosk_cap,
            policy,
            nft_object
        );

        let ticket = BorrowingTicket<T, Coin<SUI>> {
            id: object::new(ctx),
            market_id: market.id.to_inner(),
            nft: nft,
            min_price: min_price,
            borrower_kiosk_id: object::id(borrower_kiosk),
            borrower_kiosk_cap_id: object::id(borrower_kiosk_cap),
            transfer_policy_id: object::id(policy),
            max_ltv: 0,
            utilization_rate: 0,
            debt: 0,
            last_update_timestamp: 0
        };

        vector::push_back(&mut borrower_basket.borrowing_tickets, ticket.id.to_inner());
        transfer::transfer(ticket, tx_context::sender(ctx));

    }

    //TODO: Ensure references in Markets, Baskets, etc. are correctly removed
    //TODO: Ensure the position is good.
    public entry fun reclaim<T: key + store, C: key + store>(
        ticket: BorrowingTicket<T, C>,
        policy: &TransferPolicy<T>,
        marketplace: &mut SoukMarketPlace,
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        borrower_basket: &mut Basket,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {

        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            &mut marketplace.souk_kiosk,
            &marketplace.souk_kiosk_cap,
            ticket.nft,
            ticket.min_price,
            ctx
        );

        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            &mut marketplace.souk_kiosk,
            purchase_cap,
            payment
        );

        transfer_policy::confirm_request<T>(policy, transfer_req);

        kiosk::lock<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            policy,
            nft_object
        );

        transfer::transfer(ticket, @souk);

    }

    public entry fun lend<T: key + store, C: key + store>(
        marketplace: &mut SoukMarketPlace,
        market: &mut Market<T, C>,
        borrower_basket: &mut Basket,
        amount: u64,
        payment: Coin<C>,
        ctx: &mut TxContext
        ) {

            let supplied = payment.balance().value();

            coin::put(&mut market.treasury, payment);

            let ticket = LendingTicket<T, C> {
                id: object::new(ctx),
                amount_supplied:  supplied,
                to_claim: 0,
                claimed: 0,
                last_update_timestamp: 0,
                market_id: market.id.to_inner(),
            };

             vector::push_back(&mut borrower_basket.lending_tickets, ticket.id.to_inner());
             transfer::transfer(ticket, tx_context::sender(ctx));
        }
        


    public entry fun create_basket(ctx: &mut TxContext) {

        let basket = Basket {
            id: object::new(ctx),
            borrowing_tickets: vector::empty<ID>(),
            lending_tickets: vector::empty<ID>(),
        };

        transfer::transfer(basket, ctx.sender());
    }

    fun init(ctx: &mut TxContext) {
        let (kiosk, cap) = kiosk::new(ctx);

        let souk_market_place = SoukMarketPlace {
            id: object::new(ctx),
            souk_kiosk: kiosk,
            souk_kiosk_cap: cap,
            market_ids: vector::empty<ID>(),
        };

        transfer::share_object(souk_market_place);

        let souk_owner_cap = SoukOwnerCap {
            id: object::new(ctx),
        };

        transfer::transfer(souk_owner_cap, ctx.sender())

    }

    #[test]
    fun test_souk_owner_cap_creation_and_transfer() {
        use sui::test_scenario;
        let admin = @0x1;

        let mut scenario = test_scenario::begin(admin);

        {
            init(scenario.ctx());
        };

        // 1st transaction: check Publisher
        scenario.next_tx(admin);
        {
            let souk_owner_cap = scenario.take_from_sender<SoukOwnerCap>();
            // Optionally assert on publisher
            scenario.return_to_sender(souk_owner_cap);
        };

        scenario.end();
    }

    #[test]
    fun test_market_creation() {

        use sui::test_scenario;
        let admin = @0x1;

        let mut scenario = test_scenario::begin(admin);

        {
            init(scenario.ctx());
        };

        scenario.next_tx(admin);
        {
            let souk_owner_cap = scenario.take_from_sender<SoukOwnerCap>();
            let mut souk_marketplace = scenario.take_shared<SoukMarketPlace>();

            create_market<Coin<SUI>, Coin<SUI>>(souk_owner_cap, &mut souk_marketplace, scenario.ctx());

            test_scenario::return_shared<SoukMarketPlace>(souk_marketplace);            
        };

        scenario.next_tx(admin);
        {
            let souk_owner_cap = scenario.take_from_sender<SoukOwnerCap>();
            scenario.return_to_sender(souk_owner_cap);
        };

        scenario.next_tx(admin);
        {
            let market = scenario.take_from_sender<Market<Coin<SUI>, Coin<SUI>>>();
            scenario.return_to_sender(market);
        };

        scenario.end();
    }

    #[test]
    fun test_basket_creation() {

        use sui::test_scenario;
        let admin = @0x1;
        let user = @0x2;

        let mut scenario = test_scenario::begin(admin);

        {
            init(scenario.ctx());
        };


        scenario.next_tx(user);
        {
            create_basket(scenario.ctx());
        };

        scenario.next_tx(user);
        {
            let basket = scenario.take_from_sender<Basket>();
            scenario.return_to_sender(basket);
        };

        scenario.end();
    }



}
