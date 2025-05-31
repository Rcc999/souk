module souk::tickets {

    const ECannotBorrowAndRepaySimultaneously: u64 = 0;
    const ECannotBorrowOrRepayZeroAmount: u64 = 1;
    const EDebtCannotExceedMaxLTV: u64 = 2;
    const EDebtCannotBeNegative: u64 = 3;
    const ETicketNotFoundInBasket: u64 = 4;



    public struct BorrowingTicket<phantom T, phantom C> has key, store {
        id: UID,
        nft_id: ID,
        nft_min_price: u64,
        max_ltv: u64,
        utilization_rate: u64,
        debt: u64,
        last_update_timestamp: u64
    }

    public struct LendingTicket<phantom T, phantom C> has key, store {
        id: UID,
        amount_supplied: u64,
        to_claim: u64,
        claimed: u64,
        last_update_timestamp: u64
    }

    public struct Basket has key, store {
        id: UID,
        borrowing_tickets: vector<ID>,
        lending_tickets: vector<ID>,
    }

    public fun add_borrowing_ticket(basket: &mut Basket, ticket_id: ID) {
        vector::push_back(&mut basket.borrowing_tickets, ticket_id);
    }

    public fun add_lending_ticket(basket: &mut Basket, ticket_id: ID) {
        vector::push_back(&mut basket.lending_tickets, ticket_id);
    }

    public fun remove_borrowing_ticket<T, C>(basket: &mut Basket, ticket: BorrowingTicket<T, C>) {
        
        let BorrowingTicket {id, nft_id: _, nft_min_price: _, max_ltv: _, utilization_rate: _, debt: _, last_update_timestamp: _} = ticket;
        
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

        assert!(0==1, ETicketNotFoundInBasket);

        // TODO: raise error if not found
    }

    public fun remove_lending_ticket<T, C>(basket: &mut Basket, ticket: LendingTicket<T, C>) {

        let LendingTicket {id, amount_supplied: _, to_claim: _, claimed: _, last_update_timestamp: _} = ticket;

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

        assert!(0==1, ETicketNotFoundInBasket);
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

    #[allow(lint(self_transfer))]
    public fun create_borrowing_ticket<T: key + store, C>(
        basket: &mut Basket,
        nft_id: ID,
        nft_min_price: u64,
        ctx: &mut TxContext
        ) : ID {

        let max_ltv = souk::utils::compute_max_ltv();

        let ticket = BorrowingTicket<T, C> {
                id: object::new(ctx),
                nft_id: nft_id,
                nft_min_price: nft_min_price,
                max_ltv: max_ltv,
                utilization_rate: 0,
                debt: 0,
                last_update_timestamp: 0
            };

        let ticket_id = ticket.id.to_inner();

        souk::tickets::add_borrowing_ticket(basket, ticket.id.to_inner());

        transfer::public_transfer(ticket, tx_context::sender(ctx));

        ticket_id
    }

    #[allow(lint(self_transfer))]
    public fun create_lending_ticket<T: key + store, C>(
        basket: &mut Basket,
        amount_supplied: u64,
        ctx: &mut TxContext
    ) : ID {

        let ticket = LendingTicket<T, C> {
            id:  object::new(ctx),
            amount_supplied:  amount_supplied,
            to_claim: 0,
            claimed: 0,
            last_update_timestamp: 0,
        };

        let ticket_id = ticket.id.to_inner();

        vector::push_back(&mut basket.lending_tickets, ticket.id.to_inner());

        transfer::public_transfer(ticket, tx_context::sender(ctx));

        ticket_id
    }

    public fun update_borrow_ticket<T, C>(
        ticket: &mut BorrowingTicket<T, C>,
        amount_to_borrow: u64,
        amount_to_repay: u64,
        timestamp: u64
    ) {

        assert!((amount_to_borrow == 0) || (amount_to_repay == 0), ECannotBorrowAndRepaySimultaneously);
        assert!((amount_to_borrow > 0) || (amount_to_repay > 0), ECannotBorrowOrRepayZeroAmount);
        
        assert!(ticket.debt + amount_to_borrow <= ticket.max_ltv, EDebtCannotExceedMaxLTV);
        assert!(ticket.debt - amount_to_repay >= 0, EDebtCannotBeNegative);

        ticket.debt = ticket.debt + amount_to_borrow - amount_to_repay;

        ticket.utilization_rate = souk::utils::compute_utilization_rate(ticket.debt, ticket.max_ltv);
        ticket.last_update_timestamp = timestamp;

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