// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module implements version 2 of an NFT lending protocol.
/// It provides two main flows for borrowers to use their NFTs as collateral:
/// 1. NFT Transfer to Protocol Escrow: The borrower transfers their NFT directly into the protocol's kiosk.
///    The protocol can then claim it (paying the borrower a pre-agreed amount) or the borrower can cancel and retrieve it.
/// 2. PurchaseCap Transfer to Protocol: The borrower lists their NFT in their own kiosk and grants the protocol
///    a PurchaseCap. This allows the protocol to buy the NFT at the listed price. The borrower can also cancel this permission.
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
    /// Error code: The NFT is already involved in a lending process (e.g., already in escrow or has a pending permission).
    /// Prevents an NFT from being processed multiple times simultaneously.
    const EAlreadyInProcess: u64 = 3;
    /// Error code: The NFT is not currently in a lending process that the action applies to.
    /// For example, trying to cancel an escrow that doesn't exist for the NFT.
    const ENotInProcess: u64 = 4; // Note: This constant was not used in the provided code, but is good practice.
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

    /// Represents an NFT that has been transferred into the protocol's Kiosk for escrow.
    /// This struct is stored as a dynamic object field on the `LendingProtocolStore`, keyed by the NFT's ID.
    public struct NftInProtocolEscrow has store, key {
        id: UID, // Unique identifier for this escrow record.
        nft_id: ID, // The ID of the NFT in escrow.
        original_owner: address, // The address of the borrower who put the NFT into escrow.
        borrower_kiosk_id_on_listing: ID, // The ID of the borrower's kiosk from which the NFT was originally taken (for reference).
        payment_due_to_borrower: u64, // The amount of SUI the protocol must pay the borrower if it claims this NFT.
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
        listed_price: u64,       // The price at which the NFT is listed for the protocol to purchase.
        purchase_cap: PurchaseCap<T>, // The capability allowing the protocol to purchase the NFT.
    }

    /// Represents an NFT that has been claimed by the protocol (either from escrow or via PurchaseCap)
    /// and is now held as collateral.
    /// This struct is stored as a dynamic object field on the `LendingProtocolStore`, keyed by the NFT's ID,
    /// replacing either `NftInProtocolEscrow` or `NftPurchasePermission`.
    public struct NftAsCollateral has store, key {
        id: UID, // Unique identifier for this collateral record.
        nft_id: ID, // The ID of the NFT held as collateral.
        original_owner: address, // The address of the original borrower.
        amount_paid_by_protocol: u64, // The total SUI amount the protocol paid to acquire/claim the NFT (e.g., to borrower, for royalties).
    }

    // ========== Events ==========
    // Events are emitted to allow off-chain services to track the state of the lending protocol.

    /// Emitted when a borrower successfully transfers their NFT into the protocol's escrow Kiosk.
    public struct NftDepositedToEscrow has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        protocol_kiosk_id: ID, // ID of the protocol's Kiosk where the NFT is now held.
        nft_id: ID, // ID of the deposited NFT.
        original_owner: address, // Address of the borrower.
        payment_due_on_claim: u64, // SUI amount the protocol will pay the borrower if it claims the NFT.
    }

    /// Emitted when a borrower cancels the escrow and retrieves their NFT from the protocol's Kiosk.
    public struct NftEscrowCancelled has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        protocol_kiosk_id: ID, // ID of the protocol's Kiosk from which the NFT was taken.
        nft_id: ID, // ID of the NFT whose escrow was cancelled.
        original_owner: address, // Address of the borrower.
        returned_to_borrower_kiosk_id: ID, // ID of the borrower's Kiosk where the NFT was returned.
    }

    /// Emitted when the protocol claims an NFT from its escrow Kiosk.
    public struct NftClaimedFromEscrow has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        protocol_kiosk_id: ID, // ID of the protocol's Kiosk.
        nft_id: ID, // ID of the claimed NFT.
        original_owner: address, // Address of the original borrower.
        amount_paid_by_protocol: u64, // SUI amount paid by the protocol to the borrower for the NFT.
    }

    /// Emitted when a borrower grants the protocol permission to purchase their NFT (via PurchaseCap).
    public struct PurchaseCapPermissionGranted has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        nft_id: ID, // ID of the NFT.
        original_owner: address, // Address of the borrower.
        borrower_kiosk_id: ID, // ID of the borrower's Kiosk where the NFT is listed.
        listed_price: u64, // Price at which the NFT is listed for the protocol.
    }

    /// Emitted when a borrower cancels the PurchaseCap permission granted to the protocol.
    public struct PurchaseCapPermissionCancelled has copy, drop {
        protocol_store_id: ID, // ID of the `LendingProtocolStore`.
        nft_id: ID, // ID of the NFT.
        original_owner: address, // Address of the borrower.
        borrower_kiosk_id: ID, // ID of the borrower's Kiosk.
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

    // === NFT Transfer to Protocol Escrow Flow ===
    // In this flow, the borrower transfers their NFT directly to the protocol's kiosk.
    // The protocol can then choose to "claim" it by paying a pre-agreed amount to the borrower,
    // or the borrower can cancel the escrow and get their NFT back.

    /// Entry function for a borrower to transfer their NFT to the protocol's Kiosk for escrow.
    /// The NFT is first listed for 0 SUI in the borrower's kiosk, purchased by the protocol (effectively a transfer),
    /// and then locked into the protocol's kiosk.
    /// An `NftInProtocolEscrow` record is created.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `protocol_kiosk`: Mutable reference to the protocol's `Kiosk` object (must match `protocol_store.protocol_kiosk_id`).
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` where the NFT is currently held.
    /// - `borrower_kiosk_cap`: Mutable reference to the borrower's `KioskOwnerCap` to authorize listing.
    /// - `nft_id`: The `ID` of the NFT to be escrowed.
    /// - `payment_due_on_claim`: The amount of SUI the protocol must pay the borrower if it claims this NFT from escrow.
    /// - `policy`: Mutable reference to the `TransferPolicy` for the NFT type `T`. This is used to handle any transfer restrictions or royalties.
    /// - `ctx`: Mutable reference to the `TxContext` for sender information and new object creation.
    public entry fun borrower_transfer_nft_to_protocol_escrow<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        protocol_kiosk: &mut Kiosk,
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        nft_id: ID,
        payment_due_on_claim: u64,
        policy: &TransferPolicy<T>, // Policy for the NFT type T
        ctx: &mut TxContext,
    ) {
        // Assert that the provided protocol_kiosk is indeed the one managed by the protocol_store.
        assert!(object::id(protocol_kiosk) == protocol_store.protocol_kiosk_id, EInvalidKiosk);
        // Assert that this NFT is not already in some process with the protocol.
        assert!(!dof::exists_(&protocol_store.id, nft_id), EAlreadyInProcess);

        // Step 1: Borrower lists the NFT in their own kiosk for 0 SUI. This creates a PurchaseCap.
        // This is a common pattern to enable a controlled transfer via kiosk mechanics.
        let nft_purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk, borrower_kiosk_cap, nft_id, 0, ctx // List for 0 SUI
        );
        // Step 2: Protocol "purchases" the NFT from the borrower's kiosk for 0 SUI using the PurchaseCap.
        // This transfers ownership of the NFT object to this function's scope.
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk, nft_purchase_cap, coin::zero<SUI>(ctx) // "Pay" 0 SUI
        );
        // Step 3: Confirm the transfer request, satisfying any transfer policy requirements (e.g., royalties, if any were configured to be paid by buyer).
        // For a 0-price transfer, royalties might not apply or might need separate handling depending on policy.
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // Step 4: Lock the acquired NFT into the protocol's kiosk.
        kiosk::lock<T>(
            protocol_kiosk, // The protocol's Kiosk.
            &protocol_store.protocol_kiosk_cap, // The protocol's KioskOwnerCap.
            policy, // The transfer policy for the NFT.
            nft_object // The NFT object to lock.
        );

        // Step 5: Create and store the NftInProtocolEscrow record.
        let escrow_info = NftInProtocolEscrow {
            id: object::new(ctx), // New UID for the escrow record.
            nft_id: nft_id,
            original_owner: tx_context::sender(ctx), // The borrower is the transaction sender.
            borrower_kiosk_id_on_listing: object::id(borrower_kiosk), // Record borrower's kiosk ID for reference.
            payment_due_to_borrower: payment_due_on_claim, // Store the agreed payment amount.
        };
        // Add the escrow_info as a dynamic object field to the protocol_store, keyed by the nft_id.
        dof::add(&mut protocol_store.id, nft_id, escrow_info);

        // Step 6: Emit an event.
        event::emit(NftDepositedToEscrow {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            protocol_kiosk_id: protocol_store.protocol_kiosk_id,
            nft_id: nft_id,
            original_owner: tx_context::sender(ctx),
            payment_due_on_claim: payment_due_on_claim,
        });
    }

    /// Entry function for the protocol to claim an NFT that is currently in its escrow Kiosk.
    /// The protocol lists the NFT for its agreed payout price, "purchases" it from itself (transferring the payment
    /// to its kiosk's profit balance, which should then be withdrawn and sent to the borrower),
    /// and then re-locks the NFT. An `NftAsCollateral` record is created.
    ///
    /// Note: The actual transfer of `payment_from_protocol_treasury` to the `escrow_info.original_owner`
    /// is not fully implemented on-chain in this function. The coin is consumed, and the profits appear in the
    /// protocol's kiosk. An admin action would be needed to send these funds to the borrower.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `protocol_kiosk`: Mutable reference to the protocol's `Kiosk`.
    /// - `policy`: Mutable reference to the `TransferPolicy` for the NFT type `T`.
    /// - `nft_id`: The `ID` of the NFT to be claimed.
    /// - `payment_from_protocol_treasury`: A `Coin<SUI>` that the protocol provides. Its value must match `payment_due_to_borrower`.
    ///   The caller (protocol operator) is responsible for ensuring this coin comes from the protocol's funds/treasury.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun protocol_claim_nft_from_escrow<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        protocol_kiosk: &mut Kiosk, // Protocol's Kiosk
        policy: &TransferPolicy<T>, // Policy for the NFT type T
        nft_id: ID,
        payment_from_protocol_treasury: Coin<SUI>, // Coin from protocol to pay borrower
        ctx: &mut TxContext,
    ) {
        // Assert that the provided protocol_kiosk is correct.
        assert!(object::id(protocol_kiosk) == protocol_store.protocol_kiosk_id, EInvalidKiosk);
        // Potentially: assert!(tx_context::sender(ctx) == protocol_admin_address, ENotAuthorized);

        // Step 1: Retrieve and remove the NftInProtocolEscrow record. This takes ownership.
        let escrow_info_owned: NftInProtocolEscrow = dof::remove(&mut protocol_store.id, nft_id);
        // Destructure the owned struct to access its fields.
        let NftInProtocolEscrow {
            id: escrow_uid, // UID of the escrow record.
            nft_id: _, // nft_id is already an argument.
            original_owner: escrow_original_owner,
            borrower_kiosk_id_on_listing: _, // Not directly used here.
            payment_due_to_borrower: escrow_payment_due
        } = escrow_info_owned;

        // Assert the payment coin's value matches the agreed amount.
        assert!(coin::value(&payment_from_protocol_treasury) == escrow_payment_due, EIncorrectPaymentAmount);

        // Step 2: To "pay" the borrower, the protocol lists the NFT (already in its kiosk) for the `escrow_payment_due` amount.
        let nft_purchase_cap = kiosk::list_with_purchase_cap<T>(
            protocol_kiosk, &protocol_store.protocol_kiosk_cap, nft_id, escrow_payment_due, ctx
        );
        // Step 3: The protocol then "purchases" the NFT from itself using the `payment_from_protocol_treasury` coin.
        // This moves the `payment_from_protocol_treasury` coin into the `protocol_kiosk.profits` balance.
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            protocol_kiosk, nft_purchase_cap, payment_from_protocol_treasury
        );
        // The protocol admin would later need to withdraw these profits and send them to `escrow_original_owner`.

        // Step 4: Confirm the transfer request.
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // Step 5: Re-lock the NFT into the protocol's kiosk (it's now officially collateral).
        kiosk::lock<T>(
            protocol_kiosk,
            &protocol_store.protocol_kiosk_cap,
            policy,
            nft_object
        );

        // Step 6: Create and store NftAsCollateral record.
        let collateral_info = NftAsCollateral {
            id: object::new(ctx),
            nft_id: nft_id,
            original_owner: escrow_original_owner,
            amount_paid_by_protocol: escrow_payment_due, // Record the amount paid.
        };
        dof::add(&mut protocol_store.id, nft_id, collateral_info);
        object::delete(escrow_uid); // Delete the UID of the consumed NftInProtocolEscrow record.

        // Step 7: Emit an event.
        event::emit(NftClaimedFromEscrow {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            protocol_kiosk_id: protocol_store.protocol_kiosk_id,
            nft_id: nft_id,
            original_owner: escrow_original_owner,
            amount_paid_by_protocol: escrow_payment_due,
        });
    }

    /// Entry function for a borrower to cancel an NFT escrow and retrieve their NFT.
    /// The NFT is taken from the protocol's Kiosk, and locked back into the borrower's specified `borrower_return_kiosk`.
    /// The `NftInProtocolEscrow` record is deleted.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `protocol_kiosk`: Mutable reference to the protocol's `Kiosk`.
    /// - `borrower_return_kiosk`: Mutable reference to the borrower's `Kiosk` where the NFT should be returned.
    /// - `borrower_kiosk_cap`: Mutable reference to the `KioskOwnerCap` for the `borrower_return_kiosk`.
    /// - `nft_id`: The `ID` of the NFT to be retrieved.
    /// - `policy`: Mutable reference to the `TransferPolicy` for the NFT type `T`.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun borrower_cancel_nft_escrow<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        protocol_kiosk: &mut Kiosk, // Protocol's Kiosk
        borrower_return_kiosk: &mut Kiosk, // Borrower's Kiosk to return NFT to
        borrower_kiosk_cap: &KioskOwnerCap, // Cap for borrower's return Kiosk
        nft_id: ID,
        policy: &TransferPolicy<T>, // Policy for the NFT type T
        ctx: &mut TxContext,
    ) {
        // Assert that the provided protocol_kiosk is correct.
        assert!(object::id(protocol_kiosk) == protocol_store.protocol_kiosk_id, EInvalidKiosk);

        // Step 1: Retrieve and remove the NftInProtocolEscrow record.
        let escrow_info_owned: NftInProtocolEscrow = dof::remove(&mut protocol_store.id, nft_id);
        let NftInProtocolEscrow {
            id: escrow_uid,
            nft_id: _,
            original_owner: escrow_original_owner,
            borrower_kiosk_id_on_listing: _,
            payment_due_to_borrower: _
        } = escrow_info_owned;

        // Assert that the sender is the original owner who put the NFT in escrow.
        assert!(tx_context::sender(ctx) == escrow_original_owner, ENotAuthorized);

        // Step 2: To retrieve the NFT, list it in the protocol's kiosk for 0 SUI.
        let nft_purchase_cap = kiosk::list_with_purchase_cap<T>(
            protocol_kiosk, &protocol_store.protocol_kiosk_cap, nft_id, 0, ctx
        );
        // Step 3: "Purchase" the NFT from the protocol's kiosk for 0 SUI.
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            protocol_kiosk, nft_purchase_cap, coin::zero<SUI>(ctx)
        );
        // Step 4: Confirm the transfer request.
        transfer_policy::confirm_request<T>(policy, transfer_req);

        // Step 5: Lock the retrieved NFT into the borrower's specified return kiosk.
        kiosk::lock<T>(
            borrower_return_kiosk,
            borrower_kiosk_cap,
            policy,
            nft_object
        );
        object::delete(escrow_uid); // Delete the UID of the consumed NftInProtocolEscrow record.

        // Step 6: Emit an event.
        event::emit(NftEscrowCancelled {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            protocol_kiosk_id: protocol_store.protocol_kiosk_id,
            nft_id: nft_id,
            original_owner: escrow_original_owner,
            returned_to_borrower_kiosk_id: object::id(borrower_return_kiosk),
        });
    }

    // === PurchaseCap Transfer to Protocol Flow ===
    // In this flow, the borrower lists their NFT in their own kiosk at a specific price
    // and grants the protocol a PurchaseCap. This allows the protocol to buy the NFT
    // directly from the borrower's kiosk at that price.

    /// Entry function for a borrower to grant the protocol permission to purchase their NFT.
    /// The borrower lists the NFT in their own Kiosk at `list_price` and the resulting `PurchaseCap`
    /// is stored in an `NftPurchasePermission` record associated with the protocol.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` where the NFT is listed.
    /// - `borrower_kiosk_cap`: Mutable reference to the borrower's `KioskOwnerCap`.
    /// - `nft_id`: The `ID` of the NFT.
    /// - `list_price`: The price at which the borrower lists the NFT for the protocol to purchase.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun borrower_grant_purchase_cap_permission<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        borrower_kiosk: &mut Kiosk, // Borrower's Kiosk
        borrower_kiosk_cap: &KioskOwnerCap, // Borrower's Kiosk OwnerCap
        nft_id: ID,
        list_price: u64, // Price at which NFT is listed for protocol
        ctx: &mut TxContext
    ) {
        // Assert that this NFT is not already in some process with the protocol.
        assert!(!dof::exists_(&protocol_store.id, nft_id), EAlreadyInProcess);

        // Step 1: Borrower lists the NFT in their kiosk for `list_price`, obtaining a PurchaseCap.
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft_id,
            list_price,
            ctx
        );

        // Step 2: Create and store the NftPurchasePermission record.
        let permission = NftPurchasePermission<T> {
            id: object::new(ctx), // New UID for the permission record.
            nft_id: nft_id,
            original_owner: tx_context::sender(ctx), // Borrower is the sender.
            borrower_kiosk_id: object::id(borrower_kiosk), // Record borrower's kiosk ID.
            listed_price: list_price, // Store the listed price.
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
            listed_price: list_price
        });
    }

    /// Entry function for the protocol to claim an NFT using a granted `PurchaseCap`.
    /// The protocol uses the stored `PurchaseCap` to buy the NFT from the borrower's Kiosk.
    /// The NFT is then locked into the protocol's target Kiosk. An `NftAsCollateral` record is created.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `protocol_target_kiosk`: Mutable reference to the protocol's `Kiosk` where the claimed NFT will be locked.
    ///   (Must match `protocol_store.protocol_kiosk_id`).
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` from which the NFT is purchased.
    ///   (Must match the one stored in `NftPurchasePermission`).
    /// - `nft_id`: The `ID` of the NFT to be claimed.
    /// - `policy`: Mutable reference to the `TransferPolicy` for the NFT type `T`.
    /// - `payment_from_protocol`: A `Coin<SUI>` provided by the protocol. Its value must be >= `listed_price`.
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
            listed_price: perm_listed_price,
            purchase_cap: perm_purchase_cap // This is the actual PurchaseCap object.
        } = permission_owned;

        // Assert the borrower's kiosk is correct.
        assert!(object::id(borrower_kiosk) == perm_borrower_kiosk_id, EInvalidKiosk);
        // Assert the payment is sufficient (can be greater if overpaying, but typically exact).
        assert!(coin::value(&payment_from_protocol) >= perm_listed_price, EIncorrectPaymentAmount);

        // Step 2: Protocol purchases the NFT from the borrower's kiosk using the PurchaseCap and payment.
        // The `payment_from_protocol` coin is transferred to the borrower's kiosk profits.
        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            borrower_kiosk,
            perm_purchase_cap, // Use the owned PurchaseCap.
            payment_from_protocol
        );

        // The actual amount paid to the borrower is the listed price.
        // Royalties, if any, would be handled by the transfer_policy mechanism, potentially reducing
        // the net amount to the seller or requiring additional payment from the buyer (protocol here).
        // For simplicity, we assume `perm_listed_price` is what the borrower expects.
        let actual_amount_paid_to_borrower = perm_listed_price;
        // Step 3: Confirm the transfer request, satisfying policy requirements.
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
            amount_paid_by_protocol: actual_amount_paid_to_borrower, // Record the amount paid to borrower.
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
            amount_paid_by_protocol: actual_amount_paid_to_borrower,
        });
    }

    /// Entry function for a borrower to cancel a `PurchaseCap` permission they previously granted.
    /// The `PurchaseCap` is returned to the borrower's Kiosk, and the `NftPurchasePermission` record is deleted.
    ///
    /// Arguments:
    /// - `protocol_store`: Mutable reference to the `LendingProtocolStore`.
    /// - `borrower_kiosk`: Mutable reference to the borrower's `Kiosk` (must match the one in the permission record).
    /// - `nft_id`: The `ID` of the NFT for which permission is being cancelled.
    /// - `ctx`: Mutable reference to the `TxContext`.
    public entry fun borrower_cancel_purchase_cap_permission<T: key + store>(
        protocol_store: &mut LendingProtocolStore,
        borrower_kiosk: &mut Kiosk, // Borrower's Kiosk
        nft_id: ID,
        ctx: &mut TxContext
    ) {
        // Step 1: Retrieve and remove the NftPurchasePermission record.
        let permission_owned: NftPurchasePermission<T> = dof::remove(&mut protocol_store.id, nft_id);
        let NftPurchasePermission {
            id: permission_uid,
            nft_id: _,
            original_owner: perm_original_owner,
            borrower_kiosk_id: perm_borrower_kiosk_id,
            listed_price: _, // Not used here.
            purchase_cap: perm_purchase_cap // The owned PurchaseCap object.
        } = permission_owned;

        // Assert the sender is the original owner.
        assert!(tx_context::sender(ctx) == perm_original_owner, ENotAuthorized);
        // Assert the provided borrower_kiosk is the correct one.
        assert!(object::id(borrower_kiosk) == perm_borrower_kiosk_id, EInvalidKiosk);

        // Step 2: Return the PurchaseCap to the borrower's kiosk. This effectively delists the NFT under that cap.
        kiosk::return_purchase_cap<T>(borrower_kiosk, perm_purchase_cap);
        object::delete(permission_uid); // Delete the UID of the consumed NftPurchasePermission record.

        // Step 3: Emit an event.
        event::emit(PurchaseCapPermissionCancelled {
            protocol_store_id: object::uid_to_inner(&protocol_store.id),
            nft_id: nft_id,
            original_owner: perm_original_owner,
            borrower_kiosk_id: perm_borrower_kiosk_id,
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
        // This is safer than immediately removing if checks might fail or if the record might not exist.
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
        // This could involve removing the NftAsCollateral record and transferring the NFT back.
        // For example:
        // let collateral_info_owned: NftAsCollateral = dof::remove(&mut protocol_store.id, nft_id);
        // object::delete(collateral_info_owned.id);
        // ... then logic to transfer NFT back to borrower ...

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