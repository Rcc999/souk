module souk::utils {

    public fun compute_max_ltv(): u64 {
        1000000
    }

    public fun compute_ltv(debt: u64, collateral_value: u64): u64 {
        if (collateral_value == 0) { 0 } 
        else { (debt * 10000) / collateral_value }  // Returns basis points
    }

    // Calculate utilization ratio
    public fun compute_utilization_ratio(total_borrowed: u64, total_supplied: u64): u64 {
        if (total_supplied == 0) { 0 } 
        else { (total_borrowed * 10000) / total_supplied }  // Returns basis points
    }

    // Calculate loan age in days
    public fun get_loan_age_days(creation_timestamp: u64, current_timestamp: u64): u64 {
        if (current_timestamp <= creation_timestamp) { 0 }
        else { (current_timestamp - creation_timestamp) / (24 * 60 * 60 * 1000) }  // Convert ms to days
    }

    // Calculate position interest rate
    public fun compute_position_interest_rate(
        current_ltv: u64,           // In basis points
        max_ltv: u64,               // In basis points  
        utilization_ratio: u64,     // In basis points
        loan_age_days: u64,
        base_rate: u64,             // Annual rate in basis points
        ltv_multiplier: u64,
        utilization_multiplier: u64,
        time_factor: u64,
        max_time_penalty: u64
    ): u64 {
        let ltv_premium = if (max_ltv == 0) { 0 } else { (current_ltv * ltv_multiplier) / max_ltv };
        let utilization_premium = (utilization_ratio * utilization_multiplier) / 10000;
        let time_penalty = std::u64::min(loan_age_days * time_factor, max_time_penalty);
        
        base_rate + ltv_premium + utilization_premium + time_penalty
    }

    // Calculate accrued interest for a time period
    public fun compute_accrued_interest(
        principal: u64,
        annual_rate_bp: u64,        // Annual rate in basis points
        time_elapsed_ms: u64
    ): u64 {
        let annual_ms = 365 * 24 * 60 * 60 * 1000;  // Milliseconds in a year
        (principal * annual_rate_bp * time_elapsed_ms) / (10000 * annual_ms)
    }
}