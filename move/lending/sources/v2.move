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

    /// Entry function for a borrower to grant the protocol permission to purchase their NFT,
    /// and for the protocol to immediately claim the NFT. The protocol will attempt to pay
    /// 0 SUI, or a specified royalty amount if provided by the borrower.
    /// The borrower lists the NFT in their own Kiosk for 0 SUI. The `PurchaseCap`
    /// is used by the protocol for the purchase attempt.
    /// If the NFT's TransferPolicy requires more than this (e.g., a minimum price not covered,
    /// or if actual royalties exceed the specified amount), or if the protocol treasury
    /// cannot cover the specified royalty, the entire transaction reverts.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` where the NFT is listed.
    /// - `borrower_kiosk_cap`: Mutable reference to the borrower's `KioskOwnerCap`.
    /// - `protocol_target_kiosk`: Mutable reference to the protocol's `Kiosk` where the claimed NFT will be locked.
    /// - `nft_id`: The `ID` of the NFT.
    /// - `policy`: Mutable reference to the `TransferPolicy` for the NFT type `T`.
    /// - `royalty_to_pay_if_any`: The SUI amount for royalties the protocol should attempt to pay. 
    ///                              Pass 0 to attempt a 0 SUI transfer (if no royalties are expected or known).
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun borrower_grant_purchase_cap_permission<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        borrower_kiosk: &mut Kiosk, // Borrower's Kiosk
        borrower_kiosk_cap: &KioskOwnerCap, // Borrower's Kiosk OwnerCap
        protocol_target_kiosk: &mut Kiosk, // Protocol's Kiosk to lock NFT into
        nft_id: ID,
        policy: &TransferPolicy<T>, // Policy for the NFT type T
        royalty_to_pay_if_any: u64, // Protocol attempts to pay this for royalties, or 0.
        ctx: &mut TxContext
    ) {
        // Assert that this NFT is not already in some process with the protocol
        // (e.g., already held as NftAsCollateral).
        assert!(!dof::exists_(&protocol_store.id, nft_id), EAlreadyInProcess);

        // Part 1: Borrower lists the NFT and grants PurchaseCap.
        let current_sender = tx_context::sender(ctx);
        let current_borrower_kiosk_id = object::id(borrower_kiosk);

        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft_id,
            0, // Always list for 0 SUI
            ctx
        );

        let permission = NftPurchasePermission<T> {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: current_sender,
            borrower_kiosk_id: current_borrower_kiosk_id,
            listed_price: 0,
            purchase_cap: purchase_cap,
        };
        dof::add(&mut protocol_store.id, nft_id, permission);

        event::emit(PurchaseCapPermissionGranted {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            original_owner: current_sender,
            borrower_kiosk_id: current_borrower_kiosk_id,
            listed_price: 0
        });

        // Part 2: Protocol automatically attempts to claim the NFT.

        // Assert the protocol's target kiosk is correct.
        assert!(object::id(protocol_target_kiosk) == protocol_store.protocol_kiosk_id, EInvalidKiosk);

        // The protocol will pay the specified royalty amount (or 0) from its treasury.
        let amount_to_pay_by_protocol = royalty_to_pay_if_any;
        let payment_for_claim_coin = coin::take(&mut protocol_store.protocol_treasury, amount_to_pay_by_protocol, ctx);

        // Retrieve and remove the NftPurchasePermission record that was just added.
        let permission_owned: NftPurchasePermission<T> = dof::remove(&mut protocol_store.id, nft_id);
        let NftPurchasePermission {
            id: permission_uid,
            nft_id: _, // nft_id is an argument.
            original_owner: perm_original_owner,
            borrower_kiosk_id: perm_borrower_kiosk_id,
            listed_price: perm_listed_price, // This will be 0
            purchase_cap: perm_purchase_cap
        } = permission_owned;

        // Sanity checks (should hold true based on Part 1 execution)
        assert!(perm_original_owner == current_sender, ENotAuthorized); // Should be the one who granted
        assert!(perm_borrower_kiosk_id == current_borrower_kiosk_id, EInvalidKiosk);
        // perm_listed_price is 0. amount_to_pay_by_protocol must be >= 0.
        assert!(amount_to_pay_by_protocol >= perm_listed_price, EIncorrectPaymentAmount);

        // Protocol purchases the NFT from the borrower's kiosk using the PurchaseCap and the determined payment.
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk, // Borrower's kiosk from arguments
            perm_purchase_cap,
            payment_for_claim_coin // Coin taken from protocol treasury based on suggested_payment_for_claim
        );

        // Confirm the transfer request, satisfying policy requirements.
        // If policy requires > amount_to_pay_by_protocol, this fails, reverting the entire transaction.
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // Lock the acquired NFT into the protocol's target kiosk.
        kiosk::lock<T>(
            protocol_target_kiosk,
            &protocol_store.protocol_kiosk_cap,
            policy,
            nft_object
        );

        // Create and store NftAsCollateral record.
        let collateral_info = NftAsCollateral {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: perm_original_owner, // This is current_sender
            amount_paid_by_protocol: amount_to_pay_by_protocol, // Store the actual amount protocol took (0 or royalty)
        };
        // The dynamic field for nft_id was NftPurchasePermission, now it will be NftAsCollateral.
        dof::add(&mut protocol_store.id, nft_id, collateral_info);
        object::delete(permission_uid); // Delete the UID of the consumed NftPurchasePermission object.

        // Emit NftClaimedWithPurchaseCap event.
        event::emit(NftClaimedWithPurchaseCap {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            protocol_kiosk_id: protocol_store.protocol_kiosk_id,
            nft_id: nft_id,
            original_owner: perm_original_owner,
            borrower_kiosk_id: perm_borrower_kiosk_id,
            amount_paid_by_protocol: amount_to_pay_by_protocol,
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

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}