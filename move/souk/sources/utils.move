module souk::utils {

    public fun compute_max_ltv(): u64 {
        1000000
    }

    public fun compute_utilization_rate(debt: u64, max_ltv: u64): u64 {
        if (max_ltv == 0) {
            0
        } else {
            (debt * 100) / max_ltv
        }
    }
}