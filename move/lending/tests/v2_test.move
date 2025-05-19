#[test_only]
module lending::nft_lending_v2_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::test_utils::assert_eq;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
    use sui::object::{Self, ID};
    use sui::transfer;
    use lending::nft_lending_v2::{Self, LendingProtocolStore, NftPurchasePermission, NftAsCollateral};
    use lending::test_nft::{Self, TestNFT};
    use lending::test_transfer_policy::{Self, create_for_testing, share_for_testing};

    // Test constants
    const PROTOCOL_ADMIN: address = @0xAD;
    const BORROWER: address = @0xB0;
    const NFT_VALUE: u64 = 100;
    const PROTOCOL_PAYMENT: u64 = 1000; // Protocol pays more than NFT value to cover potential royalties

    // Test helper functions
    fun create_test_nft(ctx: &mut sui::tx_context::TxContext): TestNFT {
        test_nft::create(ctx, NFT_VALUE)
    }

    fun create_transfer_policy(ctx: &mut sui::tx_context::TxContext): TransferPolicy<TestNFT> {
        let (policy, cap) = create_for_testing(ctx, PROTOCOL_ADMIN);
        // Store the cap in the sender's address for later use
        transfer::public_transfer(cap, PROTOCOL_ADMIN);
        policy
    }

    // Test initialization
    #[test]
    fun test_init() {
        let mut scenario_val = ts::begin(BORROWER);
        let scenario = &mut scenario_val;
        
        // Initialize the protocol
        ts::next_tx(scenario, BORROWER);
        {
            lending::nft_lending_v2::init_for_testing(ts::ctx(scenario));
        };

        // Verify protocol store was created and shared
        ts::next_tx(scenario, BORROWER);
        {
            let store = ts::take_shared<LendingProtocolStore>(scenario);
            let kiosk_id = lending::nft_lending_v2::protocol_kiosk_id_for_testing(&store);
            assert!(object::id(&store) != kiosk_id, 0);
            ts::return_shared(store);
        };
        ts::end(scenario_val);
    }

    // Test full lending flow
    #[test]
    fun test_full_lending_flow() {
        let mut scenario_val = ts::begin(BORROWER);
        let scenario = &mut scenario_val;
        
        let mut protocol_kiosk_id_for_test: ID = object::id_from_bytes(b"proto_kiosk_placeholder");
        ts::next_tx(scenario, BORROWER);
        {
            lending::nft_lending_v2::init_for_testing(ts::ctx(scenario));
            let store = ts::take_shared<LendingProtocolStore>(scenario);
            protocol_kiosk_id_for_test = lending::nft_lending_v2::protocol_kiosk_id_for_testing(&store);
            ts::return_shared(store);
        };

        let nft_id_for_flow: ID;
        // let borrower_kiosk_id_for_test: ID; // Not strictly needed if we pass objects

        ts::next_tx(scenario, BORROWER);
        {
            let nft = create_test_nft(ts::ctx(scenario));
            nft_id_for_flow = test_nft::id(&nft);
            let policy = create_transfer_policy(ts::ctx(scenario));
            test_nft::transfer(nft, BORROWER, ts::ctx(scenario));
            transfer::public_share_object(policy);
        };

        // Borrower creates kiosk and lists NFT (borrower owns it at this point)
        ts::next_tx(scenario, BORROWER);
        {
            let nft_to_place = ts::take_from_sender<TestNFT>(scenario);
            let (mut kiosk, kiosk_cap) = kiosk::new(ts::ctx(scenario));
            // borrower_kiosk_id_for_test = object::id(&kiosk);
            kiosk::place(&mut kiosk, &kiosk_cap, nft_to_place);
            transfer::public_transfer(kiosk, BORROWER); // Kiosk owned by BORROWER
            transfer::public_transfer(kiosk_cap, BORROWER);
        };

        // Borrower grants purchase cap permission (still BORROWER's context)
        ts::next_tx(scenario, BORROWER)
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            let mut kiosk_owned_by_borrower = ts::take_from_sender<Kiosk>(scenario); // Borrower takes their own kiosk
            let kiosk_cap_owned_by_borrower = ts::take_from_sender<KioskOwnerCap>(scenario); // Borrower takes their own cap
            
            lending::nft_lending_v2::borrower_grant_purchase_cap_permission<TestNFT>(
                &mut store,
                &mut kiosk_owned_by_borrower,
                &kiosk_cap_owned_by_borrower,
                nft_id_for_flow,
                ts::ctx(scenario)
            );

            ts::return_shared(store);
            // For the next step (claim by PROTOCOL_ADMIN), BORROWER now transfers their kiosk to PROTOCOL_ADMIN.
            // This is the artificial part for the test to work with the current claim signature.
            transfer::public_transfer(kiosk_owned_by_borrower, PROTOCOL_ADMIN);
            // KioskOwnerCap stays with BORROWER (or could be made irrelevant if not used after this by BORROWER).
            ts::return_to_sender(scenario, kiosk_cap_owned_by_borrower);
        };

        // Protocol claims NFT
        ts::next_tx(scenario, PROTOCOL_ADMIN);
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            let policy = ts::take_shared<TransferPolicy<TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(PROTOCOL_PAYMENT, ts::ctx(scenario));

            // For protocol_target_kiosk: it's shared. PROTOCOL_ADMIN takes it by ID.
            let mut protocol_kiosk_obj = ts::take_object_by_id<Kiosk>(scenario, protocol_kiosk_id_for_test);

            // Borrower's kiosk was transferred to PROTOCOL_ADMIN in the previous transaction.
            let mut borrower_kiosk_obj = ts::take_from_sender<Kiosk>(scenario); // PROTOCOL_ADMIN now takes it.

            lending::nft_lending_v2::protocol_claim_nft_with_purchase_cap<TestNFT>(
                &mut store,
                &mut protocol_kiosk_obj, // Protocol's kiosk
                &mut borrower_kiosk_obj,  // Borrower's kiosk (now with PROTOCOL_ADMIN for test)
                nft_id_for_flow,
                &policy,
                payment,
                ts::ctx(scenario)
            );

            ts::return_shared(store);
            ts::return_shared(policy);
            // Kiosks are now with PROTOCOL_ADMIN contextually in this test flow
            transfer::public_transfer(protocol_kiosk_obj, PROTOCOL_ADMIN);
            transfer::public_transfer(borrower_kiosk_obj, PROTOCOL_ADMIN);
        };

        // Borrower reimburses protocol
        ts::next_tx(scenario, BORROWER); 
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            let reimbursement = coin::mint_for_testing<SUI>(PROTOCOL_PAYMENT, ts::ctx(scenario));

            lending::nft_lending_v2::reimburse_protocol_for_collateral_payment(
                &mut store,
                nft_id_for_flow, 
                reimbursement,
                ts::ctx(scenario)
            );
            ts::return_shared(store);
        };
        ts::end(scenario_val);
    }

    // Test error cases
    #[test]
    #[expected_failure(abort_code = lending::nft_lending_v2::ENotAuthorized)]
    fun test_unauthorized_reimbursement() {
        let mut scenario_val = ts::begin(BORROWER);
        let scenario = &mut scenario_val;
        
        // Initialize protocol
        ts::next_tx(scenario, BORROWER);
        {
            lending::nft_lending_v2::init_for_testing(ts::ctx(scenario));
        };

        // Simulate an NFT that has been claimed by the protocol by directly creating a relevant NftAsCollateral record.
        // This avoids the complex flow of actually claiming it for this specific error test.
        // We need a valid NFT ID for this.
        let mut placeholder_nft_id_for_reimbursement: ID = object::id_from_bytes(b"placeholder_nft");

        ts::next_tx(scenario, BORROWER); // Borrower context to create a dummy NftAsCollateral for testing this path
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            // Create a dummy NFT just to get an ID. This NFT isn't actually used beyond its ID.
            let dummy_nft_for_id = test_nft::create(ts::ctx(scenario), 1);
            placeholder_nft_id_for_reimbursement = test_nft::id(&dummy_nft_for_id);

            // Simulate that this NFT is collateral in the store, supposedly claimed from BORROWER
            let collateral_record = NftAsCollateral {
                id: object::new(ts::ctx(scenario)),
                nft_id: placeholder_nft_id_for_reimbursement,
                original_owner: BORROWER, // BORROWER is the one who should be able to reimburse
                amount_paid_by_protocol: PROTOCOL_PAYMENT,
            };
            dof::add(&mut store.id, placeholder_nft_id_for_reimbursement, collateral_record);
            ts::return_shared(store);
            // The dummy_nft_for_id can be transferred or burned if necessary, or just left with BORROWER.
            transfer::public_transfer(dummy_nft_for_id, BORROWER); 
        };

        // Now, PROTOCOL_ADMIN (unauthorized) tries to reimburse for this placeholder_nft_id
        ts::next_tx(scenario, PROTOCOL_ADMIN);
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            let reimbursement_coin = coin::mint_for_testing<SUI>(PROTOCOL_PAYMENT, ts::ctx(scenario));
            
            // This call should fail with ENotAuthorized because PROTOCOL_ADMIN is not BORROWER
            lending::nft_lending_v2::reimburse_protocol_for_collateral_payment(
                &mut store,
                placeholder_nft_id_for_reimbursement, // The ID of the NFT supposedly held by the protocol
                reimbursement_coin,
                ts::ctx(scenario)
            );

            ts::return_shared(store);
            // If the call failed as expected, the coin is not consumed by the protocol.
            // Depending on exact error handling, coin might need to be manually handled or burned.
            // For now, assume test framework handles unspent coins in failing tx.
        };

        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = lending::nft_lending_v2::EAlreadyInProcess)]
    fun test_double_grant_permission() {
        let mut scenario_val = ts::begin(BORROWER);
        let scenario = &mut scenario_val;
        
        // Initialize protocol
        ts::next_tx(scenario, BORROWER);
        {
            lending::nft_lending_v2::init_for_testing(ts::ctx(scenario));
        };

        // Create and setup NFT
        // Declare nft_id_for_double_grant when it gets its actual value
        let nft_id_for_double_grant: ID;

        ts::next_tx(scenario, BORROWER);
        {
            let nft = create_test_nft(ts::ctx(scenario));
            nft_id_for_double_grant = test_nft::id(&nft); // Assign the ID
            let (mut kiosk, kiosk_cap) = kiosk::new(ts::ctx(scenario));
            kiosk::place(&mut kiosk, &kiosk_cap, nft);
            transfer::public_transfer(kiosk, BORROWER);
            transfer::public_transfer(kiosk_cap, BORROWER);
        };

        // Grant permission first time
        ts::next_tx(scenario, BORROWER);
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            let mut kiosk = ts::take_from_sender<Kiosk>(scenario);
            let kiosk_cap = ts::take_from_sender<KioskOwnerCap>(scenario);
            // Use the assigned nft_id_for_double_grant
            lending::nft_lending_v2::borrower_grant_purchase_cap_permission<TestNFT>(
                &mut store,
                &mut kiosk,
                &kiosk_cap,
                nft_id_for_double_grant,
                ts::ctx(scenario)
            );

            ts::return_shared(store);
            ts::return_to_sender(scenario, kiosk);
            ts::return_to_sender(scenario, kiosk_cap);
        };

        // Try to grant permission again - should fail
        ts::next_tx(scenario, BORROWER);
        {
            let mut store = ts::take_shared<LendingProtocolStore>(scenario);
            let mut kiosk = ts::take_from_sender<Kiosk>(scenario);
            let kiosk_cap = ts::take_from_sender<KioskOwnerCap>(scenario);
            // Use the assigned nft_id_for_double_grant
            lending::nft_lending_v2::borrower_grant_purchase_cap_permission<TestNFT>(
                &mut store,
                &mut kiosk,
                &kiosk_cap,
                nft_id_for_double_grant,
                ts::ctx(scenario)
            );

            ts::return_shared(store);
            ts::return_to_sender(scenario, kiosk);
            ts::return_to_sender(scenario, kiosk_cap);
        };

        ts::end(scenario_val);
    }
}
