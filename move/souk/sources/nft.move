/*
/// Module: NFT
module NFT::NFT;
*/

// For Move coding conventions, see
// https://docs.sui.io/concepts/sui-move-concepts/conventions

module souk::nft {

    use std::string::{utf8, String};
    use sui::event;
    use sui::display;
    use sui::url::{Self, Url};
    use sui::tx_context::{sender};
    use sui::transfer_policy::{Self};
    use sui::package::{Publisher};

    public struct SoukNFT has key, store {
        id: UID,
        name: String,
        description: String,
        url: Url,
    }

    public struct NFTMinted has copy, drop {
            object_id: ID,
            creator: address,
            name: String,
    }

    public struct NFT has drop {}

    public entry fun mint_to_sender(
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        let nft = SoukNFT {
            id: object::new(ctx),
            name: utf8(name),
            description: utf8(description),
            url: url::new_unsafe_from_bytes(url),
        };

        event::emit(NFTMinted {
            object_id: object::id(&nft),
            creator: sender,
            name: nft.name,
        });

        transfer::public_transfer(nft, sender);
    }

    public fun transfer(nft: SoukNFT, recipient: address, _: &mut TxContext) {
            transfer::public_transfer(nft, recipient)
    }

    public entry fun get_id(nft: &SoukNFT): ID {
        nft.id.to_inner()
    }

    public entry fun create_kiosk(ctx: &mut TxContext) {
        let (kiosk, kiosk_cap) = sui::kiosk::new(ctx);

        transfer::public_transfer(kiosk, ctx.sender());
        transfer::public_transfer(kiosk_cap, ctx.sender());
    }

    #[allow(lint(share_owned))]
    fun init(otw: NFT, ctx: &mut TxContext) {

        let keys = vector[
            utf8(b"name"),
            utf8(b"description"),
            utf8(b"image_url"),
            utf8(b"thumbnail_url"),
            utf8(b"project_url"),
        ];

        let values = vector[
            utf8(b"{name}"),
            utf8(b"a cool goose out of the pond"),
            utf8(b"https://ih1.redbubble.net/image.4986086051.7887/flat,750x,075,f-pad,750x1000,f8f8f8.jpg"),
            utf8(b"https://ih1.redbubble.net/image.4986086051.7887/flat,750x,075,f-pad,750x1000,f8f8f8.jpg"),
            utf8(b"https://google.com"),
        ];
        // Claim the Publisher object.
        let publisher: Publisher = sui::package::claim(otw, ctx);

        let mut display = display::new_with_fields<SoukNFT>(
            &publisher, keys, values, ctx
        );

        display.update_version();

        let (policy, policy_cap) = transfer_policy::new<SoukNFT>(&publisher, ctx);

        transfer::public_share_object(policy);
        transfer::public_transfer(policy_cap, sender(ctx));

        transfer::public_transfer(publisher, ctx.sender());
        transfer::public_transfer(display, tx_context::sender(ctx));


    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init(NFT {}, ctx)
    }


    #[test]
    fun test_global() {
    use sui::test_scenario;
    use sui::transfer_policy::{TransferPolicy, TransferPolicyCap};
    let admin = @0x1;
    let user = @0x2;

    let mut scenario = test_scenario::begin(admin);

    let otw = NFT {};
    {
        init(otw, scenario.ctx());
    };

    // 1st transaction: check Publisher
    scenario.next_tx(admin);
    {
        let publisher = scenario.take_from_sender<Publisher>();
        // Optionally assert on publisher
        scenario.return_to_sender(publisher);
    };

    // 3rd transaction: check TransferPolicyCap and shared TransferPolicy
    scenario.next_tx(admin);
    {
        let policy_cap = scenario.take_from_sender<TransferPolicyCap<SoukNFT>>();
        // Optionally assert on policy_cap
        scenario.return_to_sender(policy_cap);
    };

    scenario.next_tx(admin);
    {
        let name = b"Test NFT";
        let description = b"Demo NFT for testing";
        let url = b"https://example.com/nft.png";
        mint_to_sender(
            name,
            description,
            url,
            scenario.ctx(),
        ) 
    };


    scenario.next_tx(admin);
    let nft = scenario.take_from_sender<SoukNFT>();
    let nft_id = nft.id.to_inner();
    scenario.return_to_sender(nft);

    scenario.next_tx(admin);
    {
        let nft = scenario.take_from_sender<SoukNFT>();
        transfer(nft, user, scenario.ctx(),);
    };

    scenario.next_tx(user);
    {
        let nft = scenario.take_from_sender<SoukNFT>();
        scenario.return_to_sender(nft);
    };

    scenario.next_tx(user);
    {
        create_kiosk(scenario.ctx());
    };

    scenario.next_tx(user);
    {
        let kiosk = scenario.take_from_sender<sui::kiosk::Kiosk>();
        let kiosk_cap = scenario.take_from_sender<sui::kiosk::KioskOwnerCap>();

        scenario.return_to_sender(kiosk);
        scenario.return_to_sender(kiosk_cap);

    };

    scenario.next_tx(user);
    {
        let kiosk = scenario.take_from_sender<sui::kiosk::Kiosk>();
        assert!(!sui::kiosk::is_locked(&kiosk, nft_id));
        scenario.return_to_sender(kiosk)
    };

    scenario.next_tx(user);
    {
        let mut kiosk = scenario.take_from_sender<sui::kiosk::Kiosk>();
        let kiosk_cap = scenario.take_from_sender<sui::kiosk::KioskOwnerCap>();

        let policy = scenario.take_shared<TransferPolicy<SoukNFT>>();
        let nft = scenario.take_from_sender<SoukNFT>();

        sui::kiosk::lock<SoukNFT>(&mut kiosk, &kiosk_cap, &policy, nft);

        scenario.return_to_sender(kiosk);
        scenario.return_to_sender(kiosk_cap);
        test_scenario::return_shared<TransferPolicy<SoukNFT>>(policy);
    };

    scenario.next_tx(user);
    {
        let kiosk = scenario.take_from_sender<sui::kiosk::Kiosk>();
        assert!(sui::kiosk::is_locked(&kiosk, nft_id));
        scenario.return_to_sender(kiosk)
    };

    scenario.end();
}


}


