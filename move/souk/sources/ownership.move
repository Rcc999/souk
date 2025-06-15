module souk::ownership {
    public struct SoukOwnerCap has key, store {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        let souk_owner_cap = SoukOwnerCap {
            id: object::new(ctx),
        };

        transfer::public_transfer(souk_owner_cap, ctx.sender());
    }
}