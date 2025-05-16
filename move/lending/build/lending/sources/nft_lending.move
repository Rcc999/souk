// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module lending::nft_lending {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap, PurchaseCap};
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::dynamic_object_field as dof;
    use sui::transfer_policy::{Self, TransferPolicy, TransferRequest}; // Assuming NFTs use transfer policies
    use std::type_name; // For type_name::get
    use std::string;    // For string::bytes and String type
    use std::ascii;      // For ascii::string

    // ========== Constants ==========

    /// Error when the sender is not the expected owner or borrower.
    const ENotAuthorized: u64 = 1;
    /// Error when the NFT is not found in the deposit info.
    const ENftNotDeposited: u64 = 2;
    /// Error for incorrect SUI amount for reimbursement.
    const EIncorrectReimbursementAmount: u64 = 3;
     /// Error if the protocol tries to claim an NFT for which it doesn't have a PurchaseCap.
    const EPurchaseCapNotFound: u64 = 4;


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
        // Potentially other loan terms here
    }

    // ========== Events ==========

    /// Emitted when a borrower gives permission to the protocol to claim their NFT.
    public struct NftDepositPermissioned has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        // nft_type_name: vector<u8>, // Temporarily commenting out due to conversion issues
        original_owner: address,
        borrower_kiosk_id: ID
    }

    /// Emitted when the protocol claims an NFT.
    public struct NftClaimedByProtocol has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        // nft_type_name: vector<u8>, // Temporarily commenting out
        original_owner: address,
        protocol_kiosk_id: ID,
        royalty_paid: u64
    }

    /// Emitted when a borrower reimburses the royalty payment.
    public struct RoyaltyReimbursed has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        original_owner: address,
        amount_reimbursed: u64
    }
    
    /// Emitted when a deposit is cancelled and PurchaseCap returned.
    public struct DepositCancelled has copy, drop {
        protocol_store_id: ID,
        nft_id: ID,
        original_owner: address
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
    /// The NFT is listed in the borrower's kiosk for 0 SUI, and the PurchaseCap is given to the protocol.
    public entry fun borrower_deposit_nft_permission<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        borrower_kiosk: &mut Kiosk, // Borrower's kiosk
        borrower_kiosk_cap: &KioskOwnerCap, // Borrower's kiosk owner cap
        nft_id: ID, // ID of the NFT to deposit
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // List the NFT in the borrower's kiosk for 0 SUI with a purchase cap.
        // The protocol will use this purchase cap to claim the NFT.
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft_id,
            0, // Price is 0, as it's a deposit, not an immediate sale to the protocol
            ctx
        );

        let deposit_permission = NftDepositPermission<T> {
            id: object::new(ctx),
            nft_id:
            nft_id,
            original_owner: sender,
            borrower_kiosk_id: object::id(borrower_kiosk),
            purchase_cap: purchase_cap, // The type T matches the NFT type
        };

        // Store the NftDepositPermission as a dynamic object field on the protocol_store
        // The key for the dynamic field is the nft_id
        dof::add(&mut protocol_store.id, nft_id, deposit_permission);

        event::emit(NftDepositPermissioned {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            // nft_type_name: string::bytes(&ascii::string(type_name::get<T>())),
            original_owner: sender,
            borrower_kiosk_id: object::id(borrower_kiosk)
        });
    }

    // Remaining functions to be implemented:
    // - protocol_claim_nft
    // - reimburse_royalty_payment
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
            purchase_cap
        } = deposit_permission;

        // Assert the borrower_kiosk object passed matches the one stored, for safety
        assert!(object::id(borrower_kiosk) == stored_borrower_kiosk_id, ENotAuthorized); // Basic check

        // 2. Record initial value of royalty coin
        let initial_royalty_coin_value = coin::value(royalty_payment_coin);

        // 3. Purchase the NFT from the borrower's kiosk using the PurchaseCap (price is 0)
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk, 
            purchase_cap, 
            coin::zero<SUI>(ctx)
        );

        // 4. Resolve TransferRequest: Pay royalties and confirm.
        // This part is highly dependent on the specific royalty rule implementation associated with TransferPolicy<T>.
        // We assume a function on the policy or a helper module handles this.
        // For example, if there's a `royalty_rule::pay(&mut *policy, &mut transfer_req, royalty_payment_coin, &clock)`
        // followed by `transfer_policy::confirm_request(policy, transfer_req, ctx)`. 
        // For now, we represent this as a conceptual step. The actual amount of SUI deducted from
        // `royalty_payment_coin` will be the royalty.
        // ** DEVELOPER ACTION: Replace with actual royalty payment logic for type T **
        // As a placeholder, we will just confirm the request if no explicit payment is made here.
        // If the policy requires payment, this confirm_request will fail unless payment is made before.
        // If the `kiosk::purchase_with_cap` or subsequent `kiosk::lock` itself handles drawing from a payment coin
        // based on policy rules, that's another model (less common for explicit royalty payout).
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // 5. Record final value of royalty coin and calculate amount paid
        let final_royalty_coin_value = coin::value(royalty_payment_coin);
        let paid_royalties = initial_royalty_coin_value - final_royalty_coin_value;

        // 6. Lock the NFT into the protocol's kiosk
        // The KioskOwnerCap is taken from the protocol_store
        kiosk::lock<T>(protocol_kiosk, &protocol_store.protocol_kiosk_cap, policy, nft_object);

        // 7. Create and store ClaimedNftInfo
        let claimed_info = ClaimedNftInfo {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: original_owner,
            royalty_paid_by_protocol: paid_royalties
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
            royalty_paid: paid_royalties
        });
    }

    /// Called by the original owner (borrower) to reimburse the protocol for royalty fees.
    public entry fun reimburse_royalty_payment(
        protocol_store: &mut LendingProtocolStore,
        nft_id: ID,                      // ID of the NFT for which royalty is being reimbursed
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
            royalty_paid_by_protocol
        } = claimed_info;

        // 2. Assert sender is the original owner
        assert!(sender == original_owner, ENotAuthorized);

        // 3. Assert reimbursement amount is correct
        assert!(coin::value(&reimbursement_coin) == royalty_paid_by_protocol, EIncorrectReimbursementAmount);

        // 4. Protocol takes the reimbursement coin.
        // The coin is passed by value, so it's now owned by this function's scope.
        // A real protocol would transfer this to a treasury or specific account.
        // To make this explicit, one might use `transfer::public_transfer(reimbursement_coin, protocol_controlled_address)`.
        // Or, if the protocol_store itself should hold funds, it would need a balance field.
        // In a real scenario, you would transfer it to the protocol's treasury.
        // coin::burn_for_testing(reimbursement_coin);
        // TODO: Properly handle the reimbursement_coin. Transfer it to a protocol-owned treasury/address.
        // For now, as a placeholder to correctly consume the Coin object, we transfer it to the sender.
        transfer::public_transfer(reimbursement_coin, sender);

        // 5. Delete the UID of the ClaimedNftInfo object (already removed from DOF)
        object::delete(claimed_info_uid);

        // 6. Emit event (using destructured values from the owned struct)
        event::emit(RoyaltyReimbursed {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            original_owner: original_owner, 
            amount_reimbursed: royalty_paid_by_protocol
        });
    }

}
