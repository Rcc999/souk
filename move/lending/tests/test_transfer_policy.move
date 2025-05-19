#[test_only]
module lending::test_transfer_policy {
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// Create a new transfer policy for testing
    public fun create_for_testing<T: key + store>(ctx: &mut TxContext, admin: address): (TransferPolicy<T>, TransferPolicyCap<T>) {
        // Use the test-only function to create a transfer policy
        // This function handles all the publisher management internally
        transfer_policy::new_for_testing(ctx)
    }

    /// Share a transfer policy for testing
    public fun share_for_testing<T: key + store>(policy: TransferPolicy<T>) {
        transfer::public_share_object(policy)
    }
} 