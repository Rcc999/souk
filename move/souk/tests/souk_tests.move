#[test_only]
module souk::souk_tests;
// uncomment this line to import the module
use souk::nft::{SoukNFT};
use souk::protocol::{SoukMarketPlace};
use souk::ownership::{Self, SoukOwnerCap};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};

use souk::markets::Market;
use souk::tickets::{Basket, BorrowingTicket, LendingTicket};

#[test]
fun test_init_protocols() {
    use sui::test_scenario;
    use sui::transfer_policy::{TransferPolicy, TransferPolicyCap};

    let admin = @0x1;
    let borrower = @0x2;
    let lender = @0x3;

    let mut scenario = test_scenario::begin(admin);

    // Init contracts
    {
        souk::nft::test_init(scenario.ctx());
        souk::protocol::test_init(scenario.ctx());
        souk::ownership::test_init(scenario.ctx());
    };


    // Create a market
    scenario.next_tx(admin);
    {
        let souk_owner_cap = scenario.take_from_sender<SoukOwnerCap>();
        let mut souk_marketplace = scenario.take_shared<SoukMarketPlace>();

        souk::protocol::register_market<SoukNFT, SUI>(souk_owner_cap, &mut souk_marketplace, scenario.ctx());

        test_scenario::return_shared<SoukMarketPlace>(souk_marketplace);
    };

    // Mint a NFT
    scenario.next_tx(admin);
    {
        let name = b"Test NFT";
        let description = b"Demo NFT for testing";
        let url = b"https://example.com/nft.png";
        souk::nft::mint_to_sender(
            name,
            description,
            url,
            scenario.ctx(),
        );
    };

    // Store the NFT's id to reuse across blocks:
    scenario.next_tx(admin);
    let nft = scenario.take_from_sender<SoukNFT>();
    let nft_id = souk::nft::get_id(&nft);
    scenario.return_to_sender(nft);

    // Transfer the NFT to the borrower
    scenario.next_tx(admin);
    {
        let nft = scenario.take_from_sender<SoukNFT>();
        souk::nft::transfer(nft, borrower, scenario.ctx(),);
    };

    // Create a basket for the borrower
    scenario.next_tx(borrower);
    {
        souk::tickets::create_basket(scenario.ctx());
    };

    // Create a basket for the lender
    scenario.next_tx(lender);
    {
        souk::tickets::create_basket(scenario.ctx());
    };

    // Create a kiosk for the borrower
    scenario.next_tx(borrower);
    {
        let (kiosk, kiosk_cap) = sui::kiosk_test_utils::get_kiosk(scenario.ctx());
        
        transfer::public_transfer(kiosk, scenario.ctx().sender());
        transfer::public_transfer(kiosk_cap, scenario.ctx().sender());
    };

    // Place the NFT inside the borrower's kiosk
    scenario.next_tx(borrower);
    {
        let mut kiosk = scenario.take_from_sender<Kiosk>();
        let kiosk_cap = scenario.take_from_sender<KioskOwnerCap>();
        let nft = scenario.take_from_sender<SoukNFT>();
        assert!(!sui::kiosk::has_item(&kiosk, nft_id));
        sui::kiosk::place(&mut kiosk, &kiosk_cap, nft);
        assert!(sui::kiosk::has_item(&kiosk, nft_id));
        scenario.return_to_sender(kiosk);
        scenario.return_to_sender(kiosk_cap);
    };

    // Request coins for borrowers
    scenario.next_tx(admin);
    {
        let coins = sui::kiosk_test_utils::get_sui(100000000000000, scenario.ctx());
        transfer::public_transfer(coins, borrower);
        let gas_coins = sui::kiosk_test_utils::get_sui(100000000000000, scenario.ctx());
        transfer::public_transfer(gas_coins, borrower);

        let coins = sui::kiosk_test_utils::get_sui(100000000000000, scenario.ctx());
        transfer::public_transfer(coins, lender);
        let gas_coins = sui::kiosk_test_utils::get_sui(100000000000000, scenario.ctx());
        transfer::public_transfer(gas_coins, lender);

        // let mut market = scenario.take_shared<Market<SoukNFT, SUI>>();

        // let payment = sui::kiosk_test_utils::get_sui(100000000000000, scenario.ctx());
        // souk::protocol::supply_to_market<SoukNFT, SUI>(&mut market, payment);
        // test_scenario::return_shared<Market<SoukNFT, SUI>>(market);
    };

    // Test to provide nft as collateral
    scenario.next_tx(borrower);
    {
        let mut kiosk = scenario.take_from_sender<Kiosk>();
        let kiosk_cap = scenario.take_from_sender<KioskOwnerCap>();
        
        let mut basket = scenario.take_from_sender<Basket>();
        let (basket_tickets, _) = souk::tickets::get_tickets_ids(&basket);
        assert!(vector::length(basket_tickets) == 0, 100);

        let policy = scenario.take_shared<TransferPolicy<SoukNFT>>();
        let mut souk_marketplace = scenario.take_shared<SoukMarketPlace>();

        let mut market = scenario.take_shared<Market<SoukNFT, SUI>>();
        let (market_tickets, _) = souk::markets::get_tickets_ids(&market);
        assert!(vector::length(market_tickets)== 0, 101); // or some error code

        let min_price = 10;

        let mut coins = scenario.take_from_sender<Coin<SUI>>();

        let payment = coin::split<SUI>(&mut coins, min_price, scenario.ctx());
        scenario.return_to_sender(coins);


        souk::protocol::provide_nft_as_collateral<SoukNFT, SUI>(
            &mut kiosk,
            &kiosk_cap,
            &mut basket,
            nft_id,
            min_price,
            &policy,
            &mut souk_marketplace,
            &mut market,
            payment,
            scenario.ctx()
        );

        scenario.return_to_sender(kiosk);
        scenario.return_to_sender(kiosk_cap);
        scenario.return_to_sender(basket);
        test_scenario::return_shared<SoukMarketPlace>(souk_marketplace);
        test_scenario::return_shared<Market<SoukNFT, SUI>>(market);
        test_scenario::return_shared<TransferPolicy<SoukNFT>>(policy);
    };

    // Check that the market object can still be accessed and that the borrower has a BorrowingTicket
    scenario.next_tx(borrower);
    {
        let basket = scenario.take_from_sender<Basket>();
        let (basket_tickets, _) = souk::tickets::get_tickets_ids(&basket);
        assert!(vector::length(basket_tickets) > 0, 100);
        let basket_ticket_id = *vector::borrow(basket_tickets, 0);

        let market = scenario.take_shared<Market<SoukNFT, SUI>>();
        let (market_tickets, _) = souk::markets::get_tickets_ids(&market);
        assert!(vector::length(market_tickets) > 0, 101); // or some error code

        let market_ticket_id = *vector::borrow(market_tickets, 0);

        assert!(market_ticket_id == basket_ticket_id, 102);

        scenario.return_to_sender(basket);
        test_scenario::return_shared<Market<SoukNFT, SUI>>(market);
    };

    // Test to lend
    scenario.next_tx(lender);
    {
        let mut basket = scenario.take_from_sender<Basket>();
        let mut market = scenario.take_shared<Market<SoukNFT, SUI>>();

        let amount = 100;

        let mut coins = scenario.take_from_sender<Coin<SUI>>();

        let payment = coin::split<SUI>(&mut coins, amount, scenario.ctx());
        scenario.return_to_sender(coins);

        souk::protocol::lend(&mut market, &mut basket, amount, payment, scenario.ctx());

        scenario.return_to_sender(basket);
        test_scenario::return_shared<Market<SoukNFT, SUI>>(market);
    };

    // Check that the market object can still be accessed and that the borrower has a BorrowingTicket
    scenario.next_tx(lender);
    {
        let basket = scenario.take_from_sender<Basket>();
        let (_, basket_tickets) = souk::tickets::get_tickets_ids(&basket);
        assert!(vector::length(basket_tickets) > 0, 100);
        let basket_ticket_id = *vector::borrow(basket_tickets, 0);

        let market = scenario.take_shared<Market<SoukNFT, SUI>>();
        let (_, market_tickets) = souk::markets::get_tickets_ids(&market);
        assert!(vector::length(market_tickets) > 0, 101); // or some error code

        let market_ticket_id = *vector::borrow(market_tickets, 0);

        assert!(market_ticket_id == basket_ticket_id, 102);
        scenario.return_to_sender(basket);
        test_scenario::return_shared<Market<SoukNFT, SUI>>(market);
    };

    scenario.next_tx(borrower);
    let coins = scenario.take_from_sender<Coin<SUI>>();
    let previous_balance = coins.value();
    scenario.return_to_sender(coins);


    scenario.next_tx(borrower);
    {
        let mut ticket = scenario.take_from_sender<BorrowingTicket<SoukNFT, SUI>>();
        let mut market = scenario.take_shared<Market<SoukNFT, SUI>>();

        souk::protocol::borrow<SoukNFT, SUI>(&mut market, &mut ticket, 10, scenario.ctx());

        scenario.return_to_sender(ticket);
        test_scenario::return_shared<Market<SoukNFT, SUI>>(market);
    };

    scenario.next_tx(borrower);
    let coins = scenario.take_from_sender<Coin<SUI>>();
    let current_balance = coins.value();
    scenario.return_to_sender(coins);

    // assert!(current_balance > previous_balance, current_balance); Does not work for now because we need to merge coins.
    scenario.end();
}

