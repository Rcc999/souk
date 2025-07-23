module souk::utils {

    // Interest rate model constants
    const BASIS_POINTS_MULTIPLIER: u64 = 10000; // For precision in calculations
    const PERCENTAGE_MULTIPLIER: u64 = 100;
    const MILLISECONDS_PER_YEAR: u64 = 31536000000; // 365 days * 24 hours * 60 minutes * 60 seconds * 1000 milliseconds

    public fun compute_max_ltv(): u64 {
        1000000
    }

    public fun compute_ltv(debt: u64, max_ltv: u64): u64 {
        if (max_ltv == 0) {
            0
        } else {
            (debt * 100) / max_ltv
        }
    }

    public fun compute_utilisation_rate(total_borrowed: u64, total_supplied: u64): u64 {
        if (total_supplied == 0) {
            0
        } else {
            (total_borrowed * PERCENTAGE_MULTIPLIER) / total_supplied
        }
    }

    public fun calculate_variable_interest_rate(
        utilisation_rate: u64,
        optimal_rate: u64,
        base_rate: u64,
        slope1: u64,
        slope2: u64
    ): u64 {
        if (utilisation_rate <= optimal_rate) {
            let rate_multiplier = (utilisation_rate * BASIS_POINTS_MULTIPLIER) / optimal_rate;
            base_rate + (rate_multiplier * slope1) / BASIS_POINTS_MULTIPLIER
        } else {
            let excess_utilisation = utilisation_rate - optimal_rate;
            let max_excess = PERCENTAGE_MULTIPLIER - optimal_rate;
            let excess_rate_multiplier = (excess_utilisation * BASIS_POINTS_MULTIPLIER) / max_excess;
            base_rate + slope1 + (excess_rate_multiplier * slope2) / BASIS_POINTS_MULTIPLIER
        }
    }

    public fun basis_points_to_percentage(basis_points: u64): u64 {
        basis_points / 100
    }

    public fun percentage_to_basis_points(percentage: u64): u64 {
        percentage * 100
    }

    // This function already implements current state approach perfectly:

    public fun calculate_accrued_interest(
        principal: u64,
        annual_rate_bp: u64,        // 🔥 Current market rate (not historical)
        time_elapsed_ms: u64
    ): u64 {
        if (principal == 0 || annual_rate_bp == 0 || time_elapsed_ms == 0) {
            return 0
        };

        // Interest = Principal × CurrentRate × Time
        (principal * annual_rate_bp * time_elapsed_ms) / (BASIS_POINTS_MULTIPLIER * MILLISECONDS_PER_YEAR)
    }
}