// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module lending::nft_lending {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap, PurchaseCap};
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::dynamic_object_field as dof;
    use sui::transfer_policy::{Self, TransferPolicy}; // Assuming NFTs use transfer policies

    // ========== Constants ==========

    /// Error when the sender is not the expected owner or borrower.
    const ENotAuthorized: u64 = 1;
    /// Error for incorrect SUI amount for reimbursement.
    const EIncorrectReimbursementAmount: u64 = 3;
    /// Error for incorrect SUI amount for NFT payment by protocol.
    const EIncorrectPaymentAmount: u64 = 4;

    // ========== Structs ==========

    /// Shared store for the lending protocol.
    /// Holds the protocol's kiosk and its owner capability.
   public struct LendingProtocolStore has key {
        id: UID,
        protocol_kiosk_id: ID, // Store the ID of the Kiosk object
        protocol_kiosk_cap: KioskOwnerCap
    }

    /// Information about an NFT for which the PurchaseCap has been transferred to the protocol.
    /// This is stored as a dynamic object field on the LendingProtocolStore, keyed by NFT ID.
    public struct NftDepositPermission<phantom T: key + store> has store, key {
        id: UID,
        nft_id: ID,
        original_owner: address, // Borrower's address
        borrower_kiosk_id: ID,   // Borrower's kiosk ID, to return if cancelled
        listed_price: u64,       // Price at which the NFT is listed by the borrower
        purchase_cap: PurchaseCap<T>
    }

    /// Information about a claimed NFT, including royalty paid.
    /// This can be stored as a dynamic object field on the LendingProtocolStore, keyed by NFT ID,
    /// replacing NftDepositPermission, or as a separate debt object.
    public struct ClaimedNftInfo has store, key {
        id: UID,
        nft_id: ID,
        original_owner: address,
        royalty_paid_by_protocol: u64,
        price_paid_to_borrower: u64 // Price paid to the borrower for the NFT
        // Potentially other loan terms here
    }

    // ========== Events ==========

    /// Emitted when a borrower gives permission to the protocol to claim their NFT.
    public struct NftDepositPermissioned has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        // nft_type_name: vector<u8>, // Temporarily commenting out due to conversion issues
        original_owner: address,
        borrower_kiosk_id: ID,
        listed_price: u64
    }

    /// Emitted when the protocol claims an NFT.
    public struct NftClaimedByProtocol has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        // nft_type_name: vector<u8>, // Temporarily commenting out
        original_owner: address,
        protocol_kiosk_id: ID,
        royalty_paid: u64,
        price_paid_to_borrower: u64
    }

    /// Emitted when a borrower reimburses the protocol for royalty fees and the NFT purchase price.
    public struct ProtocolCostsReimbursed has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        original_owner: address,
        amount_reimbursed: u64
    }
    
    /// Emitted when a deposit is cancelled and PurchaseCap returned.
    public struct DepositCancelled has copy, drop {
        // protocol_store_id: ID,
        // nft_id: ID,
        // original_owner: address

    }

    // ========== Init Function ==========

    fun init(ctx: &mut TxContext) {
        let (new_kiosk_obj, kiosk_cap) = kiosk::new(ctx);
        let kiosk_id = object::id(&new_kiosk_obj); // Get the ID of the new kiosk
        transfer::public_share_object(new_kiosk_obj); // Share the kiosk object

        let store = LendingProtocolStore {
            id: object::new(ctx),
            protocol_kiosk_id: kiosk_id, // Store the ID
            protocol_kiosk_cap: kiosk_cap
        };
        transfer::share_object(store);
    }

    // ========== Public Entry Functions ==========

    /// Called by the borrower to give the protocol permission to claim their NFT.
    /// The NFT is listed in the borrower's kiosk for list_price SUI, and the PurchaseCap is given to the protocol.
    public entry fun borrower_deposit_nft_permission<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        borrower_kiosk: &mut Kiosk, // Borrower's kiosk
        borrower_kiosk_cap: &KioskOwnerCap, // Borrower's kiosk owner cap
        nft_id: ID, // ID of the NFT to deposit
        list_price: u64, // Price at which the borrower lists the NFT
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // List the NFT in the borrower's kiosk for list_price SUI with a purchase cap.
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft_id,
            list_price, // Price for the NFT listing
            ctx
        );

        let deposit_permission = NftDepositPermission<T> {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: sender,
            borrower_kiosk_id: object::id(borrower_kiosk),
            listed_price: list_price, // Store the provided list_price
            purchase_cap: purchase_cap,
        };

        // Store the NftDepositPermission as a dynamic object field on the protocol_store
        dof::add(&mut protocol_store.id, nft_id, deposit_permission);

        event::emit(NftDepositPermissioned {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            // nft_type_name: string::bytes(&ascii::string(type_name::get<T>())),
            original_owner: sender,
            borrower_kiosk_id: object::id(borrower_kiosk),
            listed_price: list_price
        });
    }

    // Remaining functions to be implemented:
    // - protocol_claim_nft
    // - reimburse_protocol_costs
    // - (Optional) cancel_deposit_permission

    /// Called by the protocol (e.g., an admin) to claim the NFT after permission is given.
    /// The protocol pays the necessary royalties.
    public entry fun protocol_claim_nft<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        protocol_kiosk: &mut Kiosk,      // Protocol's actual Kiosk object
        borrower_kiosk: &mut Kiosk,      // Borrower's actual Kiosk object (owner of the NFT initially)
        nft_id: ID,                      // ID of the NFT to claim
        policy: &mut TransferPolicy<T>,  // TransferPolicy for the NFT type T
        royalty_payment_coin: &mut Coin<SUI>, // Coin provided by the protocol to pay royalties
        nft_payment_coin: Coin<SUI>,     // Coin provided by the protocol to pay the listed price to borrower
        ctx: &mut TxContext
    ) {
        // 1. Retrieve the NftDepositPermission
        let deposit_permission: NftDepositPermission<T> = 
            dof::remove(&mut protocol_store.id, nft_id);

        let NftDepositPermission {
            id: permission_uid,
            nft_id: _, // already have nft_id
            original_owner,
            borrower_kiosk_id: stored_borrower_kiosk_id,
            listed_price, // Retrieve the listed price
            purchase_cap
        } = deposit_permission;

        // Assert the borrower_kiosk object passed matches the one stored, for safety
        assert!(object::id(borrower_kiosk) == stored_borrower_kiosk_id, ENotAuthorized); // Basic check

        // Assert that the nft_payment_coin value matches the listed_price
        assert!(coin::value(&nft_payment_coin) == listed_price, EIncorrectPaymentAmount);

        // 2. Record initial value of royalty coin
        let initial_royalty_coin_value = coin::value(royalty_payment_coin);

        // 3. Purchase the NFT from the borrower's kiosk using the PurchaseCap
        // The nft_payment_coin is used here to pay the borrower the listed_price.
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk, 
            purchase_cap, 
            nft_payment_coin // Use the provided coin for payment
        );

        // 4. Resolve TransferRequest: Pay royalties and confirm.
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // 5. Record final value of royalty coin and calculate amount paid
        let final_royalty_coin_value = coin::value(royalty_payment_coin);
        let paid_royalties = initial_royalty_coin_value - final_royalty_coin_value;

        // 6. Lock the NFT into the protocol's kiosk
        kiosk::lock<T>(protocol_kiosk, &protocol_store.protocol_kiosk_cap, policy, nft_object);

        // 7. Create and store ClaimedNftInfo
        let claimed_info = ClaimedNftInfo {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: original_owner,
            royalty_paid_by_protocol: paid_royalties,
            price_paid_to_borrower: listed_price // Store the price paid to borrower
        };
        dof::add(&mut protocol_store.id, nft_id, claimed_info); // Overwrites NftDepositPermission
        
        // 8. Delete the UID of the now-consumed NftDepositPermission object
        object::delete(permission_uid);

        // 9. Emit event
        event::emit(NftClaimedByProtocol {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            // nft_type_name: ... (commented out previously)
            original_owner: original_owner,
            protocol_kiosk_id: object::id(protocol_kiosk),
            royalty_paid: paid_royalties,
            price_paid_to_borrower: listed_price // Emit the price paid
        });
    }

    /// Called by the original owner (borrower) to reimburse the protocol for royalty fees and the NFT purchase price.
    public entry fun reimburse_protocol_costs(
        protocol_store: &mut LendingProtocolStore,
        nft_id: ID,                      // ID of the NFT for which costs are being reimbursed
        reimbursement_coin: Coin<SUI>,   // Coin provided by the borrower for reimbursement
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // 1. Remove ClaimedNftInfo to get ownership and details
        let claimed_info: ClaimedNftInfo = 
            dof::remove(&mut protocol_store.id, nft_id);
        
        let ClaimedNftInfo {
            id: claimed_info_uid,
            nft_id: _, // already have nft_id from args
            original_owner,
            royalty_paid_by_protocol,
            price_paid_to_borrower
        } = claimed_info;

        // 2. Assert sender is the original owner
        assert!(sender == original_owner, ENotAuthorized);

        // 3. Calculate total amount due and assert reimbursement amount is correct
        let total_due = royalty_paid_by_protocol + price_paid_to_borrower;
        assert!(coin::value(&reimbursement_coin) == total_due, EIncorrectReimbursementAmount);

        // 4. Protocol takes the reimbursement coin.
        // TODO: Properly handle the reimbursement_coin. Transfer it to a protocol-owned treasury/address.
        transfer::public_transfer(reimbursement_coin, sender); // Placeholder: transfer to sender

        // 5. Delete the UID of the ClaimedNftInfo object (already removed from DOF)
        object::delete(claimed_info_uid);

        // 6. Emit event
        event::emit(ProtocolCostsReimbursed {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            original_owner: original_owner, 
            amount_reimbursed: total_due
        });
    }

    #[test_only]
    public fun protocol_kiosk_id_for_testing(store: &LendingProtocolStore): ID {
        store.protocol_kiosk_id
    }

    #[test_only]
    public fun borrower_kiosk_id_from_permission_for_testing<T: key + store>(permission: &NftDepositPermission<T>): ID {
        permission.borrower_kiosk_id
    }

    #[test_only]
    public fun store_uid_for_testing(store: &LendingProtocolStore): &UID {
        &store.id
    }
}
