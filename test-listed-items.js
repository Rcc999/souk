// Test script for querying instant sell data from collections
// Run with: node test-listed-items.js [collection-id]

import { GraphQLClient, gql } from "graphql-request";
import fetch, { Headers } from "node-fetch";

// Polyfill for Node.js compatibility
if (!globalThis.fetch) {
  globalThis.fetch = fetch;
  globalThis.Headers = Headers;
}

// Constants
const MIST_TO_SUI = 1_000_000_000; // 1 SUI = 1,000,000,000 MIST

// Tradeport API Configuration
const TRADEPORT_API_URL = "https://api.indexer.xyz/graphql";
const API_KEY = "apr0mKo.0dc2928d0a2bd8668c964e421c163510";
const API_USER = "bsa";

// GraphQL Client setup
const graphqlClient = new GraphQLClient(TRADEPORT_API_URL, {
  headers: {
    "x-api-key": API_KEY,
    "x-api-user": API_USER,
  },
});

/**
 * Convert MIST to SUI for display
 * @param {number} mistAmount - Amount in MIST
 * @returns {number} Amount in SUI
 */
function mistToSui(mistAmount) {
  return mistAmount / MIST_TO_SUI;
}

/**
 * Query collection info and bids for instant sell data
 * @param {string} collectionId - The collection ID (UUID format)
 * @returns {Promise<Object>} Collection instant sell data
 */
async function getInstantSellData(collectionId) {
  try {
    // Get collection info with current floor price and collection bids in parallel
    const [collectionResponse, bidsResponse] = await Promise.all([
      // Get collection info including current floor price
      graphqlClient.request(
        gql`
          query fetchCollectionInfo($collection_id: uuid!) {
            sui {
              collections(where: { id: { _eq: $collection_id } }) {
                id
                title
                slug
                floor
                volume
                usd_volume
              }
            }
          }
        `,
        {
          collection_id: collectionId,
        },
      ),

      // Get collection bids
      graphqlClient.request(
        gql`
          query fetchCollectionBids(
            $where: bids_bool_exp!
            $order_by: [bids_order_by!]
          ) {
            sui {
              bids(where: $where, order_by: $order_by) {
                price
                bidder
                remaining_count
                expires_at
              }
            }
          }
        `,
        {
          where: {
            collection_id: { _eq: collectionId },
            status: { _eq: "active" },
            type: { _eq: "collection" },
          },
          order_by: [{ price: "desc" }],
        },
      ),
    ]);

    if (
      !collectionResponse.sui.collections ||
      collectionResponse.sui.collections.length === 0
    ) {
      console.log("Collection not found");
      return null;
    }

    const collection = collectionResponse.sui.collections[0];
    const bids = bidsResponse.sui.bids || [];

    // Get the current floor price directly from the collection data
    const floorPrice = mistToSui(collection.floor || 0);

    const totalBids = bids.length;
    const instantSellPrice = totalBids > 0 ? mistToSui(bids[0].price) : 0;

    return {
      collectionTitle: collection.title,
      floorPrice,
      totalBids,
      instantSellPrice,
      allBids: bids,
    };
  } catch (error) {
    console.error("Error:", error.message);
    return null;
  }
}

/**
 * Test the recent_actions query for collection bid activity
 * @param {string} collectionId - The collection ID (UUID format)
 * @returns {Promise<Object>} Collection bid activity data
 */
async function getCollectionBidActivity(collectionId) {
  try {
    const activityResponse = await graphqlClient.request(
      gql`
        query fetchCollectionActivity(
          $where: recent_actions_bool_exp
          $offset: Int
          $limit: Int!
        ) {
          sui {
            actions: recent_actions(
              where: $where
              order_by: [{ block_time: desc }, { tx_index: desc }]
              offset: $offset
              limit: $limit
            ) {
              id
              type
              price
              usd_price
              price_coin
              sender
              receiver
              tx_id
              block_time
              market_name
              bought_on_tradeport
              nonce
              nft {
                id
                token_id
                token_id_index
                name
                media_url
                media_type
                ranking
                owner
                chain_state
              }
              contract {
                commission: default_commission {
                  key
                  market_fee
                  market_name
                  royalty
                  is_custodial
                }
              }
            }
          }
        }
      `,
      {
        where: {
          collection_id: {
            _eq: collectionId,
          },
          type: {
            _in: [
              "collection-bid",
              "bid",
              "solo-bid",
              "multi-collection-bid",
              "unlist-bid",
              "unlist-collection-bid",
              "cancel-collection-bid",
            ],
          },
        },
        limit: 30,
      },
    );

    const actions = activityResponse.sui.actions || [];

    console.log("\n=== Recent Bid Activity Analysis ===");
    console.log(`Total recent bid actions: ${actions.length}`);

    // Group by action type
    const typeGroups = {};
    actions.forEach((action) => {
      typeGroups[action.type] = (typeGroups[action.type] || 0) + 1;
    });

    console.log("Action types breakdown:");
    Object.entries(typeGroups).forEach(([type, count]) => {
      console.log(`  ${type}: ${count}`);
    });

    // Look at collection-bid actions specifically
    const collectionBids = actions.filter(
      (action) => action.type === "collection-bid",
    );
    console.log(`\nCollection-bid actions: ${collectionBids.length}`);

    if (collectionBids.length > 0) {
      console.log("Recent collection bid prices (MIST):");
      collectionBids.slice(0, 5).forEach((bid, index) => {
        console.log(
          `  ${index + 1}. ${mistToSui(bid.price).toFixed(4)} SUI (${new Date(bid.block_time).toLocaleString()})`,
        );
      });
    }

    return {
      totalActions: actions.length,
      typeBreakdown: typeGroups,
      collectionBids: collectionBids.length,
    };
  } catch (error) {
    console.error("Error fetching bid activity:", error.message);
    return null;
  }
}

/**
 * Main function
 */
async function main() {
  const collectionId = process.argv[2];

  if (!collectionId) {
    console.log("Usage: node test-listed-items.js [collection-id]");
    console.log(
      "Example: node test-listed-items.js 5fb36cd5-2527-44f7-9905-61096c442647",
    );
    process.exit(1);
  }

  const data = await getInstantSellData(collectionId);

  if (data) {
    console.log(`Collection: ${data.collectionTitle}`);
    console.log(`Floor Price: ${data.floorPrice.toFixed(4)} SUI`);
    console.log(`Total Active Collection Bids: ${data.totalBids}`);
    console.log(
      `Instant Sell Price: ${data.instantSellPrice > 0 ? data.instantSellPrice.toFixed(4) + " SUI" : "No bids available"}`,
    );

    // Display all active collection bids
    if (data.allBids && data.allBids.length > 0) {
      console.log("\n=== All Active Collection Bids ===");
      data.allBids.forEach((bid, index) => {
        const price = mistToSui(bid.price);
        const expiresAt = bid.expires_at
          ? new Date(bid.expires_at).toLocaleString()
          : "No expiration";
        const bidder = bid.bidder.substring(0, 8) + "...";

        console.log(
          `${index + 1}. ${price.toFixed(4)} SUI | Count: ${bid.remaining_count} | Bidder: ${bidder} | Expires: ${expiresAt}`,
        );
      });

      // Show liquidity analysis
      console.log("\n=== Liquidity Analysis ===");
      const totalLiquidity = data.allBids.reduce(
        (sum, bid) => sum + mistToSui(bid.price) * bid.remaining_count,
        0,
      );
      const totalItems = data.allBids.reduce(
        (sum, bid) => sum + bid.remaining_count,
        0,
      );
      const avgPrice = totalLiquidity / totalItems;

      console.log(`Total items that can be instantly sold: ${totalItems}`);
      console.log(
        `Total liquidity available: ${totalLiquidity.toFixed(4)} SUI`,
      );
      console.log(`Average instant sell price: ${avgPrice.toFixed(4)} SUI`);
      console.log(`Highest bid: ${data.instantSellPrice.toFixed(4)} SUI`);

      if (data.allBids.length >= 5) {
        const topFiveLiquidity = data.allBids
          .slice(0, 5)
          .reduce(
            (sum, bid) => sum + mistToSui(bid.price) * bid.remaining_count,
            0,
          );
        const topFiveItems = data.allBids
          .slice(0, 5)
          .reduce((sum, bid) => sum + bid.remaining_count, 0);
        console.log(
          `Top 5 bids: ${topFiveItems} items worth ${topFiveLiquidity.toFixed(4)} SUI`,
        );
      }
    }

    // Also test the recent activity approach
    console.log("\n=== Comparing with Recent Activity Query ===");
    await getCollectionBidActivity(collectionId);
  }
}

main().catch(console.error);
