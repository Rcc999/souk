module souk::tickets {

    use sui::object::{Self, UID, ID};
    use sui::tx_context::{TxContext};
    use souk::utils;

    const ECannotBorrowAndRepaySimultaneously: u64 = 0;
    const ECannotBorrowOrRepayZeroAmount: u64 = 1;
    const EDebtCannotExceedMaxLTV: u64 = 2;
    const EDebtCannotBeNegative: u64 = 3;
    const ETicketNotFoundInBasket: u64 = 4;

    public struct BorrowingPosition has key, store {
        id: UID,
        ticket_id: ID,
        ltv: u64,
        collateral_value: u64,
        debt: u64,
        borrowed: u64
    }

    public struct LendingPosition has key, store {
        id: UID,
        ticket_id: ID,
        amount_supplied: u64,
        to_claim: u64,
        claimed: u64
    }

    public struct BorrowingTicket<phantom T, phantom C> has key, store {
        id: UID,
        nft_id: ID,
        nft_min_price: u64,
        last_update_timestamp: u64
    }

    public struct LendingTicket<phantom T, phantom C> has key, store {
        id: UID,
        last_update_timestamp: u64
    }

    public fun get_borrowing_ticket_id<T, C>(ticket: &BorrowingTicket<T, C>) : ID {
        ticket.id.to_inner()
    }

    public fun get_lending_ticket_id<T, C>(ticket: &LendingTicket<T, C>) : ID {
        ticket.id.to_inner()
    }

    public fun get_borrowing_ticket_ids(basket: &Basket) : &vector<ID> {
        &basket.borrowing_tickets
    }

    public fun get_lending_ticket_ids(basket: &Basket) : &vector<ID> {
        &basket.lending_tickets
    }

    public fun get_borrowed(position: &BorrowingPosition): u64 {
    position.borrowed
    }

    public fun get_amount_supplied(position: &LendingPosition): u64 {
        position.amount_supplied
    }

    public fun get_to_claim(position: &LendingPosition): u64 {
        position.to_claim
    }

    public fun get_ltv(position: &BorrowingPosition): u64 {
        position.ltv
    }

    public fun get_debt(position: &BorrowingPosition): u64 {
        position.debt
    }

    public fun get_collateral_value(position: &BorrowingPosition): u64 {
        position.collateral_value
    }

    public fun add_to_debt(position: &mut BorrowingPosition, interest: u64) {
    position.debt = position.debt + interest;
    }

    public fun add_to_claim(position: &mut LendingPosition, interest: u64) {
    position.to_claim = position.to_claim + interest;
}

    public fun get_borrowing_position_info(
        position: &BorrowingPosition
    ): (ID, ID, u64, u64, u64, u64) {
        (
            position.id.to_inner(),
            position.ticket_id,
            position.ltv,
            position.collateral_value,
            position.debt,
            position.borrowed
        )
    }

    public fun get_lending_position_info(
        position: &LendingPosition
    ): (ID, ID, u64, u64, u64) {
        (
            position.id.to_inner(),
            position.ticket_id,
            position.amount_supplied,
            position.to_claim,
            position.claimed,
        )
    }

    public fun burn_borrowing_position(
        position: BorrowingPosition
    )
    {
        let BorrowingPosition {id, ticket_id: _, collateral_value: _, ltv: _, debt: _, borrowed: _} = position;
        object::delete(id);
    }

    public fun burn_lending_position(
        position: LendingPosition
    )
    {
        let LendingPosition {id, ticket_id: _, amount_supplied: _, to_claim: _, claimed: _} = position;
        object::delete(id);
    }

    public fun update_borrowing_position_collateral_value(position: &mut BorrowingPosition, new_collateral_value: u64) {
        position.collateral_value = new_collateral_value;
        let updated_ltv = souk::utils::compute_ltv(position.debt, position.collateral_value);
        position.ltv = updated_ltv;
    }

    public struct Basket has key, store {
        id: UID,
        borrowing_tickets: vector<ID>,
        lending_tickets: vector<ID>,
    }

    public fun remove_borrowing_ticket<T, C>(basket: &mut Basket, ticket: BorrowingTicket<T, C>) {
        
        let BorrowingTicket {id, nft_id: _, nft_min_price: _, last_update_timestamp: _} = ticket;
        
        let ticket_id = id.to_inner();
        object::delete(id);
        
        let len = vector::length(&basket.borrowing_tickets);
        let mut i = 0;
        while (i < len) {
            if (vector::borrow(&basket.borrowing_tickets, i) == ticket_id) {
                vector::swap_remove(&mut basket.borrowing_tickets, i);
                return
            };
            i = i + 1;
        };

        assert!(false, ETicketNotFoundInBasket);

        // TODO: raise error if not found
    }

    public fun remove_lending_ticket<T, C>(basket: &mut Basket, ticket: LendingTicket<T, C>) {

        let LendingTicket {id, last_update_timestamp: _} = ticket;

        let ticket_id = id.to_inner();
        object::delete(id);

        let len = vector::length(&basket.lending_tickets);
        let mut i = 0;
        while (i < len) {
            if (vector::borrow(&basket.lending_tickets, i) == ticket_id) {
                vector::swap_remove(&mut basket.lending_tickets, i);
                return
            };
            i = i + 1;
        };
        // TODO: raise error if not found

        assert!(false, ETicketNotFoundInBasket);
    }

    #[allow(lint(self_transfer))]
    public fun create_basket(ctx: &mut TxContext) {

        let basket = Basket {
            id: object::new(ctx),
            borrowing_tickets: vector::empty<ID>(),
            lending_tickets: vector::empty<ID>(),
        };

        transfer::transfer(basket, ctx.sender());
    }

    public fun create_borrowing_ticket<T: key + store, C>(
        basket: &mut Basket,
        nft_id: ID,
        nft_min_price: u64,
        collateral_value: u64,
        ctx: &mut TxContext
        ) : (ID, BorrowingTicket<T, C>, BorrowingPosition) {


        let ticket = BorrowingTicket<T, C> {
                id: object::new(ctx),
                nft_id: nft_id,
                nft_min_price: nft_min_price,
                last_update_timestamp: 0
            };
        
        let ticket_id = ticket.id.to_inner();
        
        let position = BorrowingPosition {
            id: object::new(ctx),
            ticket_id: ticket_id,
            collateral_value: collateral_value,
            ltv: 0,
            debt: 0,
            borrowed: 0,
        };

        vector::push_back(&mut basket.borrowing_tickets, ticket_id);

        (ticket_id, ticket, position)
    }

    public fun create_lending_ticket<T: key + store, C>(
        basket: &mut Basket,
        amount_supplied: u64,
        ctx: &mut TxContext
    ) : (ID, LendingTicket<T, C>, LendingPosition) {

        let ticket = LendingTicket<T, C> {
            id:  object::new(ctx),
            last_update_timestamp: 0,
        };

        let ticket_id = ticket.id.to_inner();

        let position = LendingPosition{
            id:  object::new(ctx),
            ticket_id: ticket_id,
            amount_supplied: amount_supplied,
            to_claim: 0,
            claimed: 0,
        };

        vector::push_back(&mut basket.lending_tickets, ticket.id.to_inner());

        (ticket_id, ticket, position)
    }

    public fun update_borrow_ticket(
        borrowing_position: &mut BorrowingPosition,
        market_max_ltv: u64,
        amount_to_borrow: u64,
        amount_to_repay: u64,
    ) {

        assert!((amount_to_borrow == 0) || (amount_to_repay == 0), ECannotBorrowAndRepaySimultaneously);
        assert!((amount_to_borrow > 0) || (amount_to_repay > 0), ECannotBorrowOrRepayZeroAmount);

        let updated_debt = borrowing_position.debt + amount_to_borrow - amount_to_repay;
        let updated_ltv = souk::utils::compute_ltv(updated_debt, borrowing_position.collateral_value);
        
        assert!(updated_ltv <= market_max_ltv, EDebtCannotExceedMaxLTV);
        assert!(updated_debt >= 0, EDebtCannotBeNegative);

        borrowing_position.debt = updated_debt;

        borrowing_position.ltv = updated_ltv;

    }


    public fun get_nft_id<T, C>(ticket: &BorrowingTicket<T, C>) : ID {
        ticket.nft_id
    }

    public fun get_nft_min_price<T, C>(ticket: &BorrowingTicket<T, C>) : u64 {
        ticket.nft_min_price
    }

    public fun get_tickets_ids(basket: &Basket) : (&vector<ID>, &vector<ID>) {
        (&basket.borrowing_tickets, &basket.lending_tickets)
    }
}