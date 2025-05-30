// #[test_only]
// module souk::souk_tests;
// // uncomment this line to import the module
// use souk::nft;
// use souk::protocol;

// const ENotImplemented: u64 = 0;

// #[test]
// fun test_init_protocols() {
//     use sui::test_scenario;
//     let admin = @0x1;
//     let user = @0x2;

//     let mut scenario = test_scenario::begin(admin);

//     let otw = souk::nft::SoukNFT {};

//     scenario.next_tx(admin);
//     {
//         let souk_owner_cap = scenario.take_from_sender<souk::protocol::SoukOwnerCap>();
//         // Optionally assert on publisher
//         scenario.return_to_sender(souk_owner_cap);
//     };

//     scenario.next_tx(user);
//     {
//         souk::protocol::create_basket(scenario.ctx());
//     };

//     scenario.next_tx(user);
//     {
//         let basket = scenario.take_from_sender<souk::protocol::Basket>();
//         scenario.return_to_sender(basket);
//     };

//     scenario.end();
// }

