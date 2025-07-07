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
 * Parse royalty percentage from chain_state
 * @param {Object} chainState - The chain_state object from collection
 * @returns {number} Royalty percentage (e.g., 5 for 5%)
 */
function parseRoyaltyFromChainState(chainState) {
  try {
    if (!chainState) return 0;

    // Check different possible structures
    if (chainState.rules && Array.isArray(chainState.rules)) {
      for (const rule of chainState.rules) {
        // Check various possible structures for royalty
        if (
          rule.rule_type === "royalty_rule" ||
          rule.type === "royalty_rule" ||
          (rule.rule && rule.rule.royalty_bp !== undefined) ||
          rule.royalty_bp !== undefined
        ) {
          const royaltyBp =
            rule.rule?.royalty_bp ||
            rule.royalty_bp ||
            rule.rule?.royalty ||
            rule.royalty ||
            0;
          return royaltyBp / 100; // Convert basis points to percentage
        }
      }
    }

    // Check if there's a direct royalty field
    if (chainState.royalty_bp !== undefined) {
      return chainState.royalty_bp / 100;
    }

    // Check transfer_policies array (most common structure)
    if (
      chainState.transfer_policies &&
      Array.isArray(chainState.transfer_policies)
    ) {
      for (const policy of chainState.transfer_policies) {
        if (policy.rules && Array.isArray(policy.rules)) {
          for (const rule of policy.rules) {
            if (rule.type === "royalty_rule" && rule.amount_bp !== undefined) {
              return rule.amount_bp / 100; // Convert basis points to percentage
            }
          }
        }
      }
    }

    // Check for other possible structures
    if (chainState.transfer_policy && chainState.transfer_policy.rules) {
      const rules = chainState.transfer_policy.rules;
      for (const rule of rules) {
        if (rule.royalty_bp !== undefined) {
          return rule.royalty_bp / 100;
        }
      }
    }

    return 0;
  } catch (error) {
    console.error("Error parsing royalty from chain_state:", error);
    return 0;
  }
}

/**
 * Calculate full purchase price including commission and royalties
 * @param {number} basePrice - Base price in SUI
 * @param {number} royaltyPercent - Royalty percentage (e.g., 5 for 5%)
 * @returns {number} Full purchase price in SUI
 */
function calculateFullPrice(basePrice, royaltyPercent = 0) {
  const commissionPercent = 3; // Tradeport's flat 3% fee
  const totalFeePercent = commissionPercent + royaltyPercent;
  return basePrice * (1 + totalFeePercent / 100);
}

/**
 * Filter bids to only include logical ones within a threshold of the floor price
 * @param {Array} bids - Array of bid objects
 * @param {number} floorPrice - Floor price in SUI
 * @param {number} thresholdPercent - Maximum percentage below floor price (default: 30%)
 * @returns {Array} Filtered array of logical bids
 */
function filterLogicalBids(bids, floorPrice, thresholdPercent = 30) {
  if (!bids || bids.length === 0 || floorPrice === 0) return bids;

  const minPrice = floorPrice * (1 - thresholdPercent / 100);

  return bids.filter((bid) => {
    const bidPrice = mistToSui(bid.price);
    return bidPrice >= minPrice;
  });
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
      // Get collection info including current floor price and chain_state for royalty info
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
                chain_state
              }
            }
          }
        `,
        {
          collection_id: collectionId,
        },
      ),

      // Get collection bids with total count
      graphqlClient.request(
        gql`
          query fetchCollectionBids(
            $where: bids_bool_exp!
            $order_by: [bids_order_by!]
            $limit: Int
          ) {
            sui {
              bids(where: $where, order_by: $order_by, limit: $limit) {
                price
                bidder
                remaining_count
                expires_at
              }
              bids_aggregate(where: $where) {
                aggregate {
                  count
                }
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
          limit: 25, // Set back to 25 since that's the API limit anyway
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
    const totalBidsCount =
      bidsResponse.sui.bids_aggregate?.aggregate?.count || 0;

    // Get the current base floor price from the collection data
    const baseFloorPrice = mistToSui(collection.floor || 0);

    // Parse royalty from chain_state
    const royaltyPercent = parseRoyaltyFromChainState(collection.chain_state);

    // Calculate full floor price including commission and royalties
    const fullFloorPrice = calculateFullPrice(baseFloorPrice, royaltyPercent);

    // Filter to only logical bids (within 30% of floor price)
    const logicalBids = filterLogicalBids(bids, baseFloorPrice, 30);

    const instantSellPrice = bids.length > 0 ? mistToSui(bids[0].price) : 0;

    return {
      collectionTitle: collection.title,
      baseFloorPrice,
      fullFloorPrice,
      royaltyPercent,
      totalBids: totalBidsCount,
      displayedBids: bids.length,
      logicalBids: logicalBids.length,
      instantSellPrice,
      allBids: bids,
      logicalBidsOnly: logicalBids,
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
    console.log(`Base Floor Price: ${data.baseFloorPrice.toFixed(4)} SUI`);
    console.log(
      `Full Floor Price (with fees): ${data.fullFloorPrice.toFixed(4)} SUI`,
    );
    console.log(
      `Royalty: ${data.royaltyPercent}% + Commission: 3% = Total Fees: ${(data.royaltyPercent + 3).toFixed(1)}%`,
    );
    console.log(
      `Total Active Collection Bids: ${data.totalBids} (showing top ${data.displayedBids}, logical: ${data.logicalBids})`,
    );
    console.log(
      `Instant Sell Price: ${data.instantSellPrice > 0 ? data.instantSellPrice.toFixed(4) + " SUI" : "No bids available"}`,
    );

    // Display logical collection bids only
    if (data.logicalBidsOnly && data.logicalBidsOnly.length > 0) {
      console.log("\n=== Logical Collection Bids (within 30% of floor) ===");
      data.logicalBidsOnly.forEach((bid, index) => {
        const price = mistToSui(bid.price);
        const expiresAt = bid.expires_at
          ? new Date(bid.expires_at).toLocaleString()
          : "No expiration";
        const bidder = bid.bidder.substring(0, 8) + "...";

        console.log(
          `${index + 1}. ${price.toFixed(4)} SUI | Count: ${bid.remaining_count} | Bidder: ${bidder} | Expires: ${expiresAt}`,
        );
      });

      // Show threshold info
      const minLogicalPrice = data.baseFloorPrice * 0.7; // 30% below floor
      console.log(
        `\nNote: Only showing bids >= ${minLogicalPrice.toFixed(4)} SUI (70% of floor price)`,
      );
    } else {
      console.log("\n=== No Logical Collection Bids Found ===");
      console.log("All bids are more than 30% below the floor price");
    }

    // Show liquidity analysis for logical bids only
    if (data.logicalBidsOnly && data.logicalBidsOnly.length > 0) {
      console.log("\n=== Logical Bids Liquidity Analysis ===");
      const logicalLiquidity = data.logicalBidsOnly.reduce(
        (sum, bid) => sum + mistToSui(bid.price) * bid.remaining_count,
        0,
      );
      const logicalItems = data.logicalBidsOnly.reduce(
        (sum, bid) => sum + bid.remaining_count,
        0,
      );
      const avgLogicalPrice = logicalLiquidity / logicalItems;

      console.log(`Logical items that can be instantly sold: ${logicalItems}`);
      console.log(
        `Logical liquidity available: ${logicalLiquidity.toFixed(4)} SUI`,
      );
      console.log(
        `Average logical instant sell price: ${avgLogicalPrice.toFixed(4)} SUI`,
      );
      console.log(
        `Highest logical bid: ${data.instantSellPrice.toFixed(4)} SUI`,
      );
      console.log(`Base floor price: ${data.baseFloorPrice.toFixed(4)} SUI`);
      console.log(
        `Full floor price (website): ${data.fullFloorPrice.toFixed(4)} SUI`,
      );

      if (data.logicalBidsOnly.length >= 5) {
        const topFiveLogicalLiquidity = data.logicalBidsOnly
          .slice(0, 5)
          .reduce(
            (sum, bid) => sum + mistToSui(bid.price) * bid.remaining_count,
            0,
          );
        const topFiveLogicalItems = data.logicalBidsOnly
          .slice(0, 5)
          .reduce((sum, bid) => sum + bid.remaining_count, 0);
        console.log(
          `Top 5 logical bids: ${topFiveLogicalItems} items worth ${topFiveLogicalLiquidity.toFixed(4)} SUI`,
        );
      }
    }

    // Also test the recent activity approach
    console.log("\n=== Comparing with Recent Activity Query ===");
    await getCollectionBidActivity(collectionId);
  }
}

main().catch(console.error);
