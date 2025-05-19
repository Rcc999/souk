#[test_only]
module lending::test_nft {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// A test NFT type that satisfies key + store constraints
    public struct TestNFT has key, store {
        id: UID,
        value: u64
    }

    /// Create a new test NFT
    public fun create(ctx: &mut TxContext, value: u64): TestNFT {
        TestNFT {
            id: object::new(ctx),
            value
        }
    }

    /// Get the NFT's value
    public fun value(nft: &TestNFT): u64 {
        nft.value
    }

    /// Get the NFT's ID
    public fun id(nft: &TestNFT): ID {
        object::id(nft)
    }

    /// Transfer the NFT to an address
    public fun transfer(nft: TestNFT, recipient: address, ctx: &mut TxContext) {
        transfer::transfer(nft, recipient)
    }
} 