// Instant Sell / Liquidation Handler
// Handles instant selling of NFTs to collection bids for liquidation scenarios

import { SuiTradingClient } from "@tradeport/sui-trading-sdk";
import { GraphQLClient, gql } from "graphql-request";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

// Constants
const MIST_TO_SUI = 1_000_000_000; // 1 SUI = 1,000,000,000 MIST

// Tradeport API Configuration
const TRADEPORT_API_URL = "https://api.indexer.xyz/graphql";
const API_KEY = "apr0mKo.0dc2928d0a2bd8668c964e421c163510";
const API_USER = "bsa";

// Sui Configuration
const SUI_NETWORK = "mainnet"; // or "testnet" for testing

// GraphQL Client setup
const graphqlClient = new GraphQLClient(TRADEPORT_API_URL, {
  headers: {
    "x-api-key": API_KEY,
    "x-api-user": API_USER,
  },
});

// Sui Trading Client setup
const suiTradingClient = new SuiTradingClient({
  apiKey: API_KEY,
  apiUser: API_USER,
});

// Sui Client setup
const suiClient = new SuiClient({
  url: getFullnodeUrl(SUI_NETWORK),
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
 * Convert SUI to MIST for transactions
 * @param {number} suiAmount - Amount in SUI
 * @returns {number} Amount in MIST
 */
function suiToMist(suiAmount) {
  return Math.floor(suiAmount * MIST_TO_SUI);
}

/**
 * Get the highest collection bid for a specific collection
 * @param {string} collectionId - The collection ID
 * @returns {Promise<Object|null>} Highest collection bid or null
 */
async function getHighestCollectionBid(collectionId) {
  try {
    const response = await graphqlClient.request(
      gql`
        query fetchHighestCollectionBid($collection_id: uuid!) {
          sui {
            bids(
              where: {
                collection_id: { _eq: $collection_id }
                status: { _eq: "active" }
                type: { _eq: "collection" }
              }
              order_by: [{ price: desc }]
              limit: 1
            ) {
              id
              price
              bidder
              remaining_count
              expires_at
              collection_id
            }
          }
        }
      `,
      {
        collection_id: collectionId,
      },
    );

    const bids = response.sui.bids || [];
    return bids.length > 0 ? bids[0] : null;
  } catch (error) {
    console.error("Error fetching highest collection bid:", error.message);
    return null;
  }
}

/**
 * Get NFT information by NFT ID
 * @param {string} nftId - The NFT ID
 * @returns {Promise<Object|null>} NFT information or null
 */
async function getNftInfo(nftId) {
  try {
    const response = await graphqlClient.request(
      gql`
        query fetchNftInfo($nft_id: uuid!) {
          sui {
            nfts(where: { id: { _eq: $nft_id } }) {
              id
              token_id
              name
              collection_id
              owner
              chain_state
              claimable
              collection {
                id
                title
                slug
              }
            }
          }
        }
      `,
      {
        nft_id: nftId,
      },
    );

    const nfts = response.sui.nfts || [];
    return nfts.length > 0 ? nfts[0] : null;
  } catch (error) {
    console.error("Error fetching NFT info:", error.message);
    return null;
  }
}

/**
 * Execute instant sell by accepting the highest collection bid
 * @param {string} nftId - The NFT ID to sell
 * @param {string} walletAddress - The wallet address of the NFT owner
 * @param {Object} [options={}] - Additional options
 * @param {number} [options.minPriceInSui] - Minimum acceptable price in SUI (optional)
 * @returns {Promise<Object>} Result of the instant sell attempt
 */
async function instantSell(nftId, walletAddress, options = {}) {
  try {
    console.log(`Starting instant sell process for NFT: ${nftId}`);

    // 1. Get NFT information
    console.log("Fetching NFT information...");
    const nft = await getNftInfo(nftId);
    if (!nft) {
      throw new Error("NFT not found");
    }

    console.log(
      `NFT Found: ${nft.name} from collection ${nft.collection.title}`,
    );
    console.log(`Owner: ${nft.owner}`);

    // 2. Verify ownership
    if (nft.owner.toLowerCase() !== walletAddress.toLowerCase()) {
      throw new Error(
        `NFT is not owned by the provided wallet address. Owner: ${nft.owner}`,
      );
    }

    // 3. Get highest collection bid
    console.log("Finding highest collection bid...");
    const highestBid = await getHighestCollectionBid(nft.collection_id);
    if (!highestBid) {
      throw new Error("No active collection bids found for this collection");
    }

    const bidPriceInSui = mistToSui(highestBid.price);
    console.log(`Highest collection bid: ${bidPriceInSui.toFixed(4)} SUI`);
    console.log(`Bidder: ${highestBid.bidder}`);
    console.log(`Remaining count: ${highestBid.remaining_count}`);

    // 4. Check minimum price if specified
    if (options.minPriceInSui && bidPriceInSui < options.minPriceInSui) {
      throw new Error(
        `Highest bid (${bidPriceInSui.toFixed(4)} SUI) is below minimum price (${options.minPriceInSui.toFixed(4)} SUI)`,
      );
    }

    // 5. Create the instant sell transaction
    console.log("Creating instant sell transaction...");
    const transaction = await suiTradingClient.acceptCollectionBid({
      bidId: highestBid.id,
      nftId: nft.id,
      walletAddress: walletAddress,
    });

    console.log("Transaction created successfully!");

    return {
      success: true,
      transaction,
      nft: {
        id: nft.id,
        name: nft.name,
        collection: nft.collection.title,
      },
      bid: {
        id: highestBid.id,
        price: bidPriceInSui,
        bidder: highestBid.bidder,
      },
      message: `Ready to sell ${nft.name} for ${bidPriceInSui.toFixed(4)} SUI`,
    };
  } catch (error) {
    console.error("Instant sell failed:", error.message);
    return {
      success: false,
      error: error.message,
      transaction: null,
    };
  }
}

/**
 * Execute instant sell with keypair (for automated liquidation)
 * @param {string} nftId - The NFT ID to sell
 * @param {Ed25519Keypair} keypair - The keypair for signing transactions
 * @param {Object} [options={}] - Additional options
 * @returns {Promise<Object>} Result of the instant sell execution
 */
async function instantSellWithKeypair(nftId, keypair, options = {}) {
  try {
    const walletAddress = keypair.getPublicKey().toSuiAddress();

    // Get the transaction
    const result = await instantSell(nftId, walletAddress, options);
    if (!result.success) {
      return result;
    }

    // Sign and execute the transaction
    console.log("Signing and executing transaction...");
    const txResult = await suiClient.signAndExecuteTransaction({
      signer: keypair,
      transaction: result.transaction,
      options: {
        showEffects: true,
        showEvents: true,
      },
    });

    console.log("Transaction executed successfully!");
    console.log(`Transaction digest: ${txResult.digest}`);

    return {
      ...result,
      executed: true,
      digest: txResult.digest,
      effects: txResult.effects,
    };
  } catch (error) {
    console.error("Transaction execution failed:", error.message);
    return {
      success: false,
      error: error.message,
      executed: false,
    };
  }
}

/**
 * Get liquidation info for an NFT (bid vs floor price analysis)
 * @param {string} nftId - The NFT ID
 * @returns {Promise<Object>} Liquidation analysis
 */
async function getLiquidationInfo(nftId) {
  try {
    const nft = await getNftInfo(nftId);
    if (!nft) {
      throw new Error("NFT not found");
    }

    const highestBid = await getHighestCollectionBid(nft.collection_id);
    if (!highestBid) {
      return {
        nft,
        canLiquidate: false,
        reason: "No collection bids available",
      };
    }

    // Get collection floor price for comparison
    const collectionResponse = await graphqlClient.request(
      gql`
        query fetchCollectionFloor($collection_id: uuid!) {
          sui {
            collections(where: { id: { _eq: $collection_id } }) {
              floor
              title
            }
          }
        }
      `,
      {
        collection_id: nft.collection_id,
      },
    );

    const collection = collectionResponse.sui.collections[0];
    const floorPrice = collection ? mistToSui(collection.floor || 0) : 0;
    const bidPrice = mistToSui(highestBid.price);

    return {
      nft: {
        id: nft.id,
        name: nft.name,
        collection: nft.collection.title,
        owner: nft.owner,
      },
      canLiquidate: true,
      liquidationData: {
        highestBidPrice: bidPrice,
        floorPrice: floorPrice,
        bidToFloorRatio: floorPrice > 0 ? (bidPrice / floorPrice) * 100 : 0,
        bidder: highestBid.bidder,
        bidId: highestBid.id,
      },
    };
  } catch (error) {
    return {
      canLiquidate: false,
      error: error.message,
    };
  }
}

// Example usage and exports
export {
  instantSell,
  instantSellWithKeypair,
  getLiquidationInfo,
  getHighestCollectionBid,
  getNftInfo,
  mistToSui,
  suiToMist,
};

// CLI usage example
if (import.meta.url === `file://${process.argv[1]}`) {
  const nftId = process.argv[2];
  const walletAddress = process.argv[3];

  if (!nftId || !walletAddress) {
    console.log("Usage: node instant-sell.js [nft-id] [wallet-address]");
    console.log(
      "Example: node instant-sell.js 123e4567-e89b-12d3-a456-426614174000 0x1234...",
    );
    process.exit(1);
  }

  // Example: Get liquidation info
  getLiquidationInfo(nftId)
    .then((info) => {
      console.log("🔍 Liquidation Analysis:");
      console.log(JSON.stringify(info, null, 2));
    })
    .catch(console.error);
}
