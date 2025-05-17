#[test_only]
module lending::nft_lending_tests {
    // TxContext, ID, UID, Coin are aliased by default.
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap}; // Self for kiosk::new
    use sui::coin::{mint_for_testing as mint_coin};
    use sui::sui::SUI;

    use sui::test_scenario::{Self, Scenario}; // Self for module functions, Scenario for type
    use sui::transaction_effects::TransactionEffects; // For the type of 'effects'

    use sui::dynamic_object_field as dof;
    use sui::transfer_policy::{new_for_testing as new_transfer_policy_for_testing};
    
    // test_utils is used for destroy only in these tests.
    use sui::test_utils; 

    use lending::nft_lending::{
        Self as nft_lending_module, LendingProtocolStore, NftDepositPermission, ClaimedNftInfo, 
        NftDepositPermissioned, NftClaimedByProtocol, RoyaltyReimbursed, 
        store_uid_for_testing, protocol_kiosk_id_for_testing, 
        borrower_kiosk_id_from_permission_for_testing
    };

    public struct MockNFT has key, store {
        id: sui::object::UID, 
        name: vector<u8>
    }

    fun new_mock_nft(name: vector<u8>, ctx: &mut sui::tx_context::TxContext): MockNFT {
        MockNFT { id: sui::object::new(ctx), name }
    }

    const ADMIN: address = @0xA;
    const BORROWER: address = @0xB;

    #[test]
    fun test_init_and_borrower_deposit() {
        let mut scenario = test_scenario::begin(BORROWER); 
        let borrower_kiosk_id: sui::object::ID;
        let borrower_kiosk_cap_id: sui::object::ID;

        scenario.next_tx(BORROWER);
        {
            let (borrower_kiosk_obj, borrower_kiosk_cap_obj) = kiosk::new(scenario.ctx());
            borrower_kiosk_id = sui::object::id(&borrower_kiosk_obj);
            borrower_kiosk_cap_id = sui::object::id(&borrower_kiosk_cap_obj);
            sui::transfer::public_share_object(borrower_kiosk_obj);
            sui::transfer::public_transfer(borrower_kiosk_cap_obj, BORROWER);
        };
        
        let mut scenario_admin = test_scenario::begin(ADMIN);
        let store_check = scenario_admin.take_shared<LendingProtocolStore>();
        assert!(sui::object::id(&store_check) != sui::object::id_from_bytes(vector[]), 0);
        scenario_admin.return_shared(store_check);
        test_scenario::end(scenario_admin);

        scenario.next_tx(BORROWER);
        {
            let mut store = scenario.take_shared<LendingProtocolStore>();
            let mut actual_borrower_kiosk = scenario.take_shared_by_id<Kiosk>(borrower_kiosk_id);
            let borrower_kiosk_cap = scenario.take_from_sender<KioskOwnerCap>();

            let nft = new_mock_nft(b"My Test NFT", scenario.ctx());
            let nft_id = sui::object::id(&nft);
            kiosk::place(&mut actual_borrower_kiosk, &borrower_kiosk_cap, nft);

            nft_lending_module::borrower_deposit_nft_permission<MockNFT>(
                &mut store,
                &mut actual_borrower_kiosk,
                &borrower_kiosk_cap,
                nft_id,
                scenario.ctx()
            );

            let store_uid = store_uid_for_testing(&store);
            let deposit_permission_exists = dof::exists_with_type<sui::object::ID, NftDepositPermission<MockNFT>>(
                store_uid, nft_id
            );
            assert!(deposit_permission_exists, 1); 

            let effects = test_scenario::last_effects(&scenario);
            test_scenario::expect_event<NftDepositPermissioned>(&effects);

            scenario.return_shared(store);
            scenario.return_shared(actual_borrower_kiosk);
            scenario.return_to_sender(borrower_kiosk_cap);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_protocol_claim_nft() {
        let mut scenario_admin_init = test_scenario::begin(ADMIN);
        let protocol_kiosk_id = protocol_kiosk_id_for_testing(&scenario_admin_init.take_shared<LendingProtocolStore>());
        scenario_admin_init.return_shared(scenario_admin_init.take_shared<LendingProtocolStore>());
        test_scenario::end(scenario_admin_init);

        let mut scenario = test_scenario::begin(BORROWER);
        let nft_id: sui::object::ID;
        let borrower_kiosk_id: sui::object::ID;
        let borrower_kiosk_cap_id: sui::object::ID;

        scenario.next_tx(BORROWER);
        {
            let (borrower_kiosk_obj, borrower_kiosk_cap_obj) = kiosk::new(scenario.ctx());
            borrower_kiosk_id = sui::object::id(&borrower_kiosk_obj); 
            borrower_kiosk_cap_id = sui::object::id(&borrower_kiosk_cap_obj);
            sui::transfer::public_share_object(borrower_kiosk_obj);
            sui::transfer::public_transfer(borrower_kiosk_cap_obj, BORROWER);
        };

        scenario.next_tx(BORROWER);
        {
            let mut store = scenario.take_shared<LendingProtocolStore>();
            let mut actual_borrower_kiosk = scenario.take_shared_by_id<Kiosk>(borrower_kiosk_id); 
            let borrower_kiosk_cap = scenario.take_from_sender<KioskOwnerCap>();

            let nft_object = new_mock_nft(b"Claimable NFT", scenario.ctx());
            nft_id = sui::object::id(&nft_object);
            kiosk::place(&mut actual_borrower_kiosk, &borrower_kiosk_cap, nft_object);

            nft_lending_module::borrower_deposit_nft_permission<MockNFT>(
                &mut store,
                &mut actual_borrower_kiosk,
                &borrower_kiosk_cap,
                nft_id, 
                scenario.ctx()
            );
            scenario.return_shared(store);
            scenario.return_shared(actual_borrower_kiosk);
            scenario.return_to_sender(borrower_kiosk_cap);
        };

        scenario.next_tx(ADMIN);
        {
            let mut store = scenario.take_shared<LendingProtocolStore>();
            let mut actual_protocol_kiosk = scenario.take_shared_by_id<Kiosk>(protocol_kiosk_id);
            
            let store_uid = store_uid_for_testing(&store);
            let deposit_permission_ref: &NftDepositPermission<MockNFT> = dof::borrow<sui::object::ID, NftDepositPermission<MockNFT>>(
                store_uid, nft_id
            );
            let borrower_kiosk_id_from_permission = borrower_kiosk_id_from_permission_for_testing(deposit_permission_ref);
            let mut actual_borrower_kiosk_for_claim = scenario.take_shared_by_id<Kiosk>(borrower_kiosk_id_from_permission);

            let (mut policy, policy_cap) = new_transfer_policy_for_testing<MockNFT>(scenario.ctx());
            let royalty_payment_coin = mint_coin<SUI>(0, scenario.ctx());

            nft_lending_module::protocol_claim_nft<MockNFT>(
                &mut store,
                &mut actual_protocol_kiosk,
                &mut actual_borrower_kiosk_for_claim,
                nft_id, 
                &mut policy,
                &mut royalty_payment_coin,
                scenario.ctx()
            );

            let claimed_info_exists = dof::exists_with_type<sui::object::ID, ClaimedNftInfo>(
                store_uid, nft_id
            );
            assert!(claimed_info_exists, 3);

            let nft_in_protocol_kiosk = kiosk::has_item(&actual_protocol_kiosk, nft_id);
            assert!(nft_in_protocol_kiosk, 4);

            let effects = test_scenario::last_effects(&scenario);
            test_scenario::expect_event<NftClaimedByProtocol>(&effects);

            test_utils::destroy(policy_cap);
            test_utils::destroy(policy);

            scenario.return_shared(store);
            scenario.return_shared(actual_protocol_kiosk);
            scenario.return_shared(actual_borrower_kiosk_for_claim);
        };

        test_scenario::end(scenario);
    }

    #[test]
    fun test_reimburse_royalty_payment() {
        let mut scenario_admin_init = test_scenario::begin(ADMIN);
        let protocol_kiosk_id = protocol_kiosk_id_for_testing(&scenario_admin_init.take_shared<LendingProtocolStore>());
        scenario_admin_init.return_shared(scenario_admin_init.take_shared<LendingProtocolStore>());
        test_scenario::end(scenario_admin_init);
        
        let mut scenario = test_scenario::begin(BORROWER);
        let nft_id: sui::object::ID;
        let borrower_kiosk_id: sui::object::ID;
        let borrower_kiosk_cap_id: sui::object::ID;

        scenario.next_tx(BORROWER);
        {
            let (borrower_kiosk_obj, borrower_kiosk_cap_obj) = kiosk::new(scenario.ctx());
            borrower_kiosk_id = sui::object::id(&borrower_kiosk_obj);
            borrower_kiosk_cap_id = sui::object::id(&borrower_kiosk_cap_obj);
            sui::transfer::public_share_object(borrower_kiosk_obj);
            sui::transfer::public_transfer(borrower_kiosk_cap_obj, BORROWER);
        };

        scenario.next_tx(BORROWER);
        {
            let mut store = scenario.take_shared<LendingProtocolStore>();
            let mut actual_borrower_kiosk = scenario.take_shared_by_id<Kiosk>(borrower_kiosk_id);
            let borrower_kiosk_cap = scenario.take_from_sender<KioskOwnerCap>();
            
            let nft_object = new_mock_nft(b"Reimbursable NFT", scenario.ctx());
            nft_id = sui::object::id(&nft_object);
            kiosk::place(&mut actual_borrower_kiosk, &borrower_kiosk_cap, nft_object);

            nft_lending_module::borrower_deposit_nft_permission<MockNFT>(
                &mut store,
                &mut actual_borrower_kiosk,
                &borrower_kiosk_cap,
                nft_id,
                scenario.ctx()
            );
            scenario.return_shared(store);
            scenario.return_shared(actual_borrower_kiosk);
            scenario.return_to_sender(borrower_kiosk_cap);
        };

        let reimbursement_coin_value = 1000;
        scenario.next_tx(ADMIN);
        {
            let mut store = scenario.take_shared<LendingProtocolStore>();
            let mut actual_protocol_kiosk = scenario.take_shared_by_id<Kiosk>(protocol_kiosk_id);
            
            let store_uid = store_uid_for_testing(&store);
            let deposit_permission_ref: &NftDepositPermission<MockNFT> = dof::borrow<sui::object::ID, NftDepositPermission<MockNFT>>(
                store_uid, nft_id
            );
            let borrower_kiosk_id_from_permission = borrower_kiosk_id_from_permission_for_testing(deposit_permission_ref);
            let mut actual_borrower_kiosk_for_claim = scenario.take_shared_by_id<Kiosk>(borrower_kiosk_id_from_permission);

            let (mut policy, policy_cap) = new_transfer_policy_for_testing<MockNFT>(scenario.ctx());
            let royalty_payment_coin = mint_coin<SUI>(reimbursement_coin_value, scenario.ctx()); 

            nft_lending_module::protocol_claim_nft<MockNFT>(
                &mut store,
                &mut actual_protocol_kiosk,
                &mut actual_borrower_kiosk_for_claim,
                nft_id,
                &mut policy,
                &mut royalty_payment_coin, 
                scenario.ctx()
            );
            
            test_utils::destroy(policy_cap);
            test_utils::destroy(policy);

            scenario.return_shared(store);
            scenario.return_shared(actual_protocol_kiosk);
            scenario.return_shared(actual_borrower_kiosk_for_claim);
        };

        scenario.next_tx(ADMIN);
        {
            let mut store = scenario.take_shared<LendingProtocolStore>();
            
            let coin_for_reimbursement = mint_coin<SUI>(reimbursement_coin_value, scenario.ctx());

            nft_lending_module::reimburse_royalty_payment(
                &mut store,
                nft_id,
                coin_for_reimbursement, 
                scenario.ctx()
            );

            let store_uid = store_uid_for_testing(&store);
            let claimed_info_exists_after_reimburse = dof::exists_with_type<sui::object::ID, ClaimedNftInfo>(
                store_uid, nft_id
            );
            assert!(!claimed_info_exists_after_reimburse, 5);

            let effects = test_scenario::last_effects(&scenario);
            test_scenario::expect_event<RoyaltyReimbursed>(&effects);
            
            scenario.return_shared(store);
        };

        test_scenario::end(scenario);
    }
} 