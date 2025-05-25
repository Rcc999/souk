module lending::souk {
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::coin::{Coin};
    use sui::sui::SUI;
    use sui::transfer_policy::{Self, TransferPolicy};

    // Stores protocol's Kiosk and capability
    public struct SoukCap has key, store {
        id: UID,
        protocol_kiosk: Kiosk,
        protocol_kiosk_cap: KioskOwnerCap,
    }

    /// Represents a claim to retrieve the NFT
    #[allow(unused_type_parameter)]
    public struct LoanTicket<T> has key, store {
        id: UID,
        original_owner: address,
        nft_id: ID,
        min_price: u64,
        borrower_kiosk_id: ID,
        borrower_kiosk_cap_id: ID,
        transfer_policy_id: ID,
    }


    // Entry to transfer NFT to protocol by having user list and sell it to themselves,
    // then the NFT gets locked in protocol's kiosk.
    public entry fun transfer_nft_to_protocol<T: key + store>(
        borrower_kiosk: &mut Kiosk,
        borrower_kiosk_cap: &KioskOwnerCap,
        nft_id: ID,
        min_price: u64,
        payment: Coin<SUI>,
        policy: &TransferPolicy<T>,
        souk_cap: &mut SoukCap,
        ctx: &mut TxContext
    ) {
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            borrower_kiosk,
            borrower_kiosk_cap,
            nft_id,
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
            &mut souk_cap.protocol_kiosk,
            &souk_cap.protocol_kiosk_cap,
            policy,
            nft_object
        );

        // Create a LoanTicket and return to user
        let ticket = LoanTicket<T> {
            id: object::new(ctx),
            original_owner: tx_context::sender(ctx),
            nft_id: nft_id,
            min_price: min_price,
            borrower_kiosk_id: object::id(borrower_kiosk),
            borrower_kiosk_cap_id: object::id(borrower_kiosk_cap),
            transfer_policy_id: object::id(policy),
        };

        transfer::transfer(ticket, tx_context::sender(ctx));
    }

    public entry fun redeem_nft<T: key + store>(
    ticket: LoanTicket<T>,
    policy: &TransferPolicy<T>,
    souk_cap: &mut SoukCap,
    borrower_kiosk: &mut Kiosk,
    borrower_kiosk_cap: &KioskOwnerCap,
    payment: Coin<SUI>,
    ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == ticket.original_owner, 0);
        let purchase_cap = kiosk::list_with_purchase_cap<T>(
            &mut souk_cap.protocol_kiosk,
            &souk_cap.protocol_kiosk_cap,
            ticket.nft_id,
            ticket.min_price,
            ctx
        );

        let (nft_object, transfer_req) = kiosk::purchase_with_cap<T>(
            &mut souk_cap.protocol_kiosk,
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

        transfer::public_transfer(ticket, @lending);

    }

    fun init(ctx: &mut TxContext) {
    let (kiosk, cap) = kiosk::new(ctx);

    let souk = SoukCap {
        id: object::new(ctx),
        protocol_kiosk: kiosk,
        protocol_kiosk_cap: cap,
    };

    transfer::share_object(souk);
    }

}
