// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module implements version 2 of an NFT lending protocol.
/// It provides a flow for borrowers to use their NFTs as collateral:
/// The borrower lists their NFT in their own kiosk and grants the protocol
/// a PurchaseCap. This allows the protocol to buy the NFT.
/// The module also handles reimbursement of costs paid by the protocol.
module lending::nft_lending_v2 {
    // Sui framework imports for core functionalities.
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap, PurchaseCap}; // For managing NFT custody and sales.
    use sui::event; // For emitting events to notify off-chain services.
    use sui::coin::{Self, Coin}; // For handling SUI coin payments.
    use sui::balance::{Self, Balance}; // For managing SUI balances, e.g., in a treasury.
    use sui::sui::SUI; // The SUI coin type.
    use sui::dynamic_object_field as dof; // For attaching dynamic data to objects.
    use sui::transfer_policy::{Self, TransferPolicy, TransferRequest}; // For handling NFT transfer policies and royalties.
    use sui::tx_context::{Self, TxContext}; // For accessing transaction context (sender, etc.).
    use sui::object::{Self, ID, UID}; // For object IDs and unique identifiers.
    use sui::transfer; // For transferring objects.

    // ========== Constants ==========

    /// Error code: The sender of the transaction is not authorized to perform the action.
    /// Typically used when an operation requires the original owner of an NFT or a specific admin.
    const ENotAuthorized: u64 = 1;
    /// Error code: The SUI coin provided for payment has an incorrect value.
    /// Used when the amount paid does not match the expected amount (e.g., listed price, reimbursement amount).
    const EIncorrectPaymentAmount: u64 = 2;
    /// Error code: The NFT is already involved in a lending process (e.g., has a pending permission).
    /// Prevents an NFT from being processed multiple times simultaneously.
    const EAlreadyInProcess: u64 = 3;
    /// Error code: The NFT is not currently in a lending process that the action applies to.
    const ENotInProcess: u64 = 4;
    /// Error code: The Kiosk object provided does not match the expected Kiosk for the operation.
    /// For instance, if the Kiosk ID in the protocol store does not match the Kiosk object passed as an argument.
    const EInvalidKiosk: u64 = 5;

    // ========== Structs ==========

    /// The main shared object for the lending protocol.
    /// It holds the protocol's Kiosk ID and its KioskOwnerCap, allowing the protocol to manage NFTs.
    /// It also includes a treasury to hold SUI.
    public struct LendingProtocolStore has key {
        id: UID, // Unique identifier for this store object.
        protocol_kiosk_id: ID, // The ID of the Kiosk object owned and managed by the protocol.
        protocol_kiosk_cap: KioskOwnerCap, // The capability to manage the protocol's Kiosk.
        protocol_treasury: Balance<SUI>, // A SUI balance to store protocol funds (e.g., reimbursements).
    }

    /// Represents permission granted by a borrower to the protocol to purchase their NFT.
    /// The NFT remains in the borrower's Kiosk, but the protocol holds the `PurchaseCap`.
    /// This struct is stored as a dynamic object field on the `LendingProtocolStore`, keyed by the NFT's ID.
    /// The `phantom T` type parameter represents the specific type of the NFT.
    public struct NftPurchasePermission<phantom T: key + store> has store, key {
        id: UID, // Unique identifier for this permission record.
        nft_id: ID, // The ID of the NFT for which permission is granted.
        original_owner: address, // The address of the borrower granting the permission.
        borrower_kiosk_id: ID,   // The ID of the borrower's Kiosk where the NFT is listed.
        listed_price: u64,       // The price at which the NFT is listed (now always 0 in grant_permission).
        purchase_cap: PurchaseCap<T>, // The capability allowing the protocol to purchase the NFT.
    }

    /// Represents an NFT that has been claimed by the protocol (via PurchaseCap)
    /// and is now held as collateral.
    /// This struct is stored as a dynamic object field on the `LendingProtocolStore`, keyed by the NFT's ID,
    /// replacing `NftPurchasePermission`.
    public struct NftAsCollateral has store, key {
        id: UID, // Unique identifier for this collateral record.
        nft_id: ID, // The ID of the NFT held as collateral.
        original_owner: address, // The address of the original borrower.
        amount_paid_by_protocol: u64, // The total SUI amount the protocol paid to acquire/claim the NFT.
    }

    // ========== Events ==========
    // Events are emitted to allow off-chain services to track the state of the lending protocol.

    /// Emitted when a borrower grants the protocol permission to purchase their NFT (via PurchaseCap).
    public struct PurchaseCapPermissionGranted has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        nft_id: ID, // ID of the NFT.
        original_owner: address, // Address of the borrower.
        borrower_kiosk_id: ID, // ID of the borrower's Kiosk where the NFT is listed.
        listed_price: u64, // Price at which the NFT is listed for the protocol (now always 0).
    }

    /// Emitted when the protocol claims an NFT using a granted PurchaseCap.
    public struct NftClaimedWithPurchaseCap has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        protocol_kiosk_id: ID, // ID of the protocol's Kiosk where the NFT is now locked.
        nft_id: ID, // ID of the claimed NFT.
        original_owner: address, // Address of the original borrower.
        borrower_kiosk_id: ID, // ID of the borrower's Kiosk from which the NFT was purchased.
        amount_paid_by_protocol: u64, // SUI amount paid by the protocol to the borrower.
    }

    /// Emitted when a borrower reimburses the protocol for costs it incurred (e.g., payment for NFT, royalties).
    public struct ProtocolCostsReimbursed has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        nft_id: ID, // ID of the NFT related to the reimbursement.
        original_owner: address, // Address of the borrower who made the reimbursement.
        amount_reimbursed: u64 // Total SUI amount reimbursed to the protocol.
    }

    // ========== Init Function ==========

    /// Initializes the lending protocol by creating the `LendingProtocolStore`.
    /// This function is called once during module deployment.
    /// It creates a new Kiosk for the protocol, shares it, and then creates and shares the `LendingProtocolStore`
    /// which holds the Kiosk's ID, its owner capability, and an empty SUI balance for the treasury.
    fun init(ctx: &mut TxContext) {
        // Create a new Kiosk for the protocol and get its owner capability.
        let (new_kiosk_obj, kiosk_cap) = kiosk::new(ctx);
        let kiosk_id = object::id(&new_kiosk_obj); // Get the ID of the newly created Kiosk.
        transfer::public_share_object(new_kiosk_obj); // Share the Kiosk object publicly.

        // Create the LendingProtocolStore.
        let store = LendingProtocolStore {
            id: object::new(ctx), // Generate a new UID for the store.
            protocol_kiosk_id: kiosk_id, // Store the ID of the protocol's Kiosk.
            protocol_kiosk_cap: kiosk_cap, // Store the KioskOwnerCap for the protocol's Kiosk.
            protocol_treasury: balance::zero(), // Initialize an empty SUI balance for the treasury.
        };
        transfer::share_object(store); // Share the LendingProtocolStore object so others can interact with it.
    }

    // === PurchaseCap Transfer to Protocol Flow ===
    // In this flow, the borrower lists their NFT in their own kiosk for 0 SUI
    // and grants the protocol a PurchaseCap. This allows the protocol to buy the NFT
    // directly from the borrower's kiosk. The payment made by the protocol must cover any creator-set minimum price and royalties.

    /// Entry function for a borrower to grant the protocol permission to purchase their NFT.
    /// The borrower lists the NFT in their own Kiosk for 0 SUI and the resulting `PurchaseCap`
    /// is stored in an `NftPurchasePermission` record associated with the protocol.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` where the NFT is listed.
    /// - `borrower_kiosk_cap`: Mutable reference to the borrower's `KioskOwnerCap`.
    /// - `nft_id`: The `ID` of the NFT.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun borrower_grant_purchase_cap_permission<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        borrower_kiosk: &mut Kiosk, // Borrower's Kiosk
        borrower_kiosk_cap: &KioskOwnerCap, // Borrower's Kiosk OwnerCap
        nft_id: ID,
        ctx: &mut TxContext
    ) {
        // Assert that this NFT is not already in some process with the protocol.
        assert!(!dof::exists_(&protocol_store.id, nft_id), EAlreadyInProcess);

        // Step 1: Borrower lists the NFT in their kiosk for 0 SUI, obtaining a PurchaseCap.
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft_id,
            0, // Always list for 0 SUI
            ctx
        );

        // Step 2: Create and store the NftPurchasePermission record.
        let permission = NftPurchasePermission<T> {
            id: object::new(ctx), // New UID for the permission record.
            nft_id: nft_id,
            original_owner: tx_context::sender(ctx), // Borrower is the sender.
            borrower_kiosk_id: object::id(borrower_kiosk), // Record borrower's kiosk ID.
            listed_price: 0, // Reflects the 0 SUI listing price.
            purchase_cap: purchase_cap, // Store the PurchaseCap.
        };
        // Add the permission record as a dynamic object field to the protocol_store.
        dof::add(&mut protocol_store.id, nft_id, permission);

        // Step 3: Emit an event.
        event::emit(PurchaseCapPermissionGranted {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            original_owner: tx_context::sender(ctx),
            borrower_kiosk_id: object::id(borrower_kiosk),
            listed_price: 0 // Emit 0 as the listed price
        });
    }

    /// Entry function for the protocol to claim an NFT using a granted `PurchaseCap`.
    /// The protocol uses the stored `PurchaseCap` to buy the NFT from the borrower's Kiosk.
    /// The NFT is then locked into the protocol's target Kiosk. An `NftAsCollateral` record is created.
    /// The payment provided by the protocol must cover any minimum price and royalties enforced by the NFT's TransferPolicy.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `protocol_target_kiosk`: Mutable reference to the protocol's `Kiosk` where the claimed NFT will be locked.
    ///   (Must match `protocol_store.protocol_kiosk_id`).
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` from which the NFT is purchased.
    ///   (Must match the one stored in `NftPurchasePermission`).
    /// - `nft_id`: The `ID` of the NFT to be claimed.
    /// - `policy`: Mutable reference to the `TransferPolicy` for the NFT type `T`.
    /// - `payment_from_protocol`: A `Coin<SUI>` provided by the protocol. This coin's value is what the protocol pays.
    ///   The caller (protocol operator) is responsible for ensuring this coin comes from the protocol's funds.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun protocol_claim_nft_with_purchase_cap<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        protocol_target_kiosk: &mut Kiosk, // Protocol's Kiosk to lock NFT into
        borrower_kiosk: &mut Kiosk,      // Borrower's Kiosk holding the NFT
        nft_id: ID,
        policy: &TransferPolicy<T>,      // Policy for the NFT type T
        payment_from_protocol: Coin<SUI>,// Coin from protocol to pay borrower
        ctx: &mut TxContext
    ) {
        // Assert the protocol's target kiosk is correct.
        assert!(object::id(protocol_target_kiosk) == protocol_store.protocol_kiosk_id, EInvalidKiosk);
        // Potentially: assert!(tx_context::sender(ctx) == protocol_admin_address, ENotAuthorized);

        // Step 1: Retrieve and remove the NftPurchasePermission record.
        let permission_owned: NftPurchasePermission<T> = dof::remove(&mut protocol_store.id, nft_id);
        // Destructure the owned permission to get its fields.
        let NftPurchasePermission {
            id: permission_uid,
            nft_id: _, // nft_id is an argument.
            original_owner: perm_original_owner,
            borrower_kiosk_id: perm_borrower_kiosk_id,
            listed_price: perm_listed_price, // This will be 0 from the modified borrower_grant_purchase_cap_permission
            purchase_cap: perm_purchase_cap // This is the actual PurchaseCap object.
        } = permission_owned;

        // Assert the borrower's kiosk is correct.
        assert!(object::id(borrower_kiosk) == perm_borrower_kiosk_id, EInvalidKiosk);
        // Assert the payment is not negative (perm_listed_price is 0).
        assert!(coin::value(&payment_from_protocol) >= perm_listed_price, EIncorrectPaymentAmount);

        // Step 2: Protocol purchases the NFT from the borrower's kiosk using the PurchaseCap and payment.
        // The `payment_from_protocol` coin is transferred to the borrower's kiosk profits (after royalties).
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk,
            perm_purchase_cap, // Use the owned PurchaseCap.
            payment_from_protocol // This coin's value is what the protocol pays.
        );

        // The amount paid by the protocol to the borrower is the value of the coin provided.
        let actual_amount_paid_to_borrower = coin::value(&payment_from_protocol);
        // Step 3: Confirm the transfer request, satisfying policy requirements.
        // The TransferPolicy will validate if `actual_amount_paid_to_borrower` meets any minimum price rules and will handle royalties.
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // Step 4: Lock the acquired NFT into the protocol's target kiosk.
        kiosk::lock<T>(
            protocol_target_kiosk,
            &protocol_store.protocol_kiosk_cap,
            policy,
            nft_object
        );

        // Step 5: Create and store NftAsCollateral record.
        let collateral_info = NftAsCollateral {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: perm_original_owner,
            amount_paid_by_protocol: actual_amount_paid_to_borrower, // Record the actual amount paid by protocol.
        };
        dof::add(&mut protocol_store.id, nft_id, collateral_info);
        object::delete(permission_uid); // Delete the UID of the consumed NftPurchasePermission record.

        // Step 6: Emit an event.
        event::emit(NftClaimedWithPurchaseCap {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            protocol_kiosk_id: protocol_store.protocol_kiosk_id,
            nft_id: nft_id,
            original_owner: perm_original_owner,
            borrower_kiosk_id: perm_borrower_kiosk_id,
            amount_paid_by_protocol: actual_amount_paid_to_borrower, // Emit the actual amount paid by protocol.
        });
    }

    // === Reimbursement Flow ===

    /// Entry function for a borrower to reimburse the protocol for costs it incurred when acquiring an NFT as collateral
    /// (e.g., payment to the borrower, royalties). The reimbursed SUI is added to the protocol's treasury.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `nft_id`: The `ID` of the NFT related to the collateral payment being reimbursed.
    /// - `reimbursement_coin`: A `Coin<SUI>` provided by the borrower. Its value must match the `amount_paid_by_protocol`
    ///   stored in the `NftAsCollateral` record.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun reimburse_protocol_for_collateral_payment(
        protocol_store: &mut LendingProtocolStore,
        nft_id: ID,
        reimbursement_coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // Step 1: Borrow an immutable reference to the NftAsCollateral record to check details.
        let collateral_info_ref: &NftAsCollateral = dof::borrow(&protocol_store.id, nft_id);
        // Assert the sender is the original owner.
        assert!(sender == collateral_info_ref.original_owner, ENotAuthorized);

        // Step 2: Get the total amount due from the collateral record.
        let total_due = collateral_info_ref.amount_paid_by_protocol;
        // Assert the reimbursement coin's value is correct.
        assert!(coin::value(&reimbursement_coin) == total_due, EIncorrectPaymentAmount);

        // Step 3: Add the reimbursement_coin to the protocol's treasury.
        coin::put(&mut protocol_store.protocol_treasury, reimbursement_coin);

        // Note: After reimbursement, the NftAsCollateral record remains.
        // A subsequent function would be needed to allow the borrower to reclaim their NFT from the protocol's kiosk
        // after the loan (represented by this reimbursement) is settled.

        // Step 4: Emit an event.
        event::emit(ProtocolCostsReimbursed {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            original_owner: collateral_info_ref.original_owner, // Use original_owner from the borrowed ref.
            amount_reimbursed: total_due
        });
    }

    // ========== Test-Only Functions ==========
    // These functions are only compiled and available in a testing environment.
    // They provide ways to inspect parts of the protocol's state for verification.

    /// Test-only function to get the protocol's Kiosk ID.
    #[test_only]
    public fun protocol_kiosk_id_for_testing(store: &LendingProtocolStore): ID {
        store.protocol_kiosk_id
    }

    /// Test-only function to get the borrower's Kiosk ID from an `NftPurchasePermission` struct.
    #[test_only]
    public fun borrower_kiosk_id_from_permission_for_testing<T: key + store>(permission: &NftPurchasePermission<T>): ID {
        permission.borrower_kiosk_id
    }

    /// Test-only function to get a reference to the `LendingProtocolStore`'s UID.
    #[test_only]
    public fun store_uid_for_testing(store: &LendingProtocolStore): &UID {
        &store.id
    }
}