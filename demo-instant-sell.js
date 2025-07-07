// Demo script for instant sell functionality
// Shows how to use the liquidation handler

import {
  instantSell,
  instantSellWithKeypair,
  getLiquidationInfo,
  getHighestCollectionBid,
  getNftInfo,
} from "./instant-sell.js";

// Example wallet address (replace with actual address)
const EXAMPLE_WALLET = "0x1234567890abcdef1234567890abcdef12345678";

// Example NFT ID (replace with actual NFT ID)
const EXAMPLE_NFT_ID = "123e4567-e89b-12d3-a456-426614174000";

/**
 * Demo 1: Analyze liquidation opportunity
 */
async function demoLiquidationAnalysis(nftId) {
  console.log("🔍 Demo 1: Liquidation Analysis");
  console.log("=".repeat(50));

  try {
    const info = await getLiquidationInfo(nftId);

    if (info.canLiquidate) {
      console.log(`✅ NFT: ${info.nft.name}`);
      console.log(`📚 Collection: ${info.nft.collection}`);
      console.log(`👤 Owner: ${info.nft.owner}`);
      console.log(
        `💰 Highest Bid: ${info.liquidationData.highestBidPrice.toFixed(4)} SUI`,
      );
      console.log(
        `🏢 Floor Price: ${info.liquidationData.floorPrice.toFixed(4)} SUI`,
      );
      console.log(
        `📊 Bid/Floor Ratio: ${info.liquidationData.bidToFloorRatio.toFixed(1)}%`,
      );
      console.log(`🎯 Bidder: ${info.liquidationData.bidder}`);

      if (info.liquidationData.bidToFloorRatio > 80) {
        console.log("🟢 GOOD LIQUIDATION OPPORTUNITY - Bid is close to floor");
      } else if (info.liquidationData.bidToFloorRatio > 60) {
        console.log("🟡 MODERATE LIQUIDATION OPPORTUNITY");
      } else {
        console.log("🔴 POOR LIQUIDATION OPPORTUNITY - Bid is far below floor");
      }
    } else {
      console.log(`❌ Cannot liquidate: ${info.reason || info.error}`);
    }
  } catch (error) {
    console.error("❌ Analysis failed:", error.message);
  }

  console.log("\n");
}

/**
 * Demo 2: Prepare instant sell transaction (without executing)
 */
async function demoPrepareInstantSell(nftId, walletAddress) {
  console.log("🔨 Demo 2: Prepare Instant Sell Transaction");
  console.log("=".repeat(50));

  try {
    const result = await instantSell(nftId, walletAddress, {
      minPriceInSui: 0.5, // Only sell if bid is >= 0.5 SUI (more realistic for demo)
    });

    if (result.success) {
      console.log("✅ Transaction prepared successfully!");
      console.log(`🎯 NFT: ${result.nft.name}`);
      console.log(`💰 Sell Price: ${result.bid.price.toFixed(4)} SUI`);
      console.log(`👤 Buyer: ${result.bid.bidder}`);
      console.log(`📄 Message: ${result.message}`);
      console.log(
        "⚠️  Transaction created but NOT executed (use a wallet to sign)",
      );
    } else {
      console.log(`❌ Failed: ${result.error}`);
    }
  } catch (error) {
    console.error("❌ Preparation failed:", error.message);
  }

  console.log("\n");
}

/**
 * Demo 3: Show collection bid info
 */
async function demoCollectionBidInfo(collectionId) {
  console.log("📊 Demo 3: Collection Bid Information");
  console.log("=".repeat(50));

  try {
    const bid = await getHighestCollectionBid(collectionId);

    if (bid) {
      console.log(
        `💰 Highest Bid: ${(bid.price / 1_000_000_000).toFixed(4)} SUI`,
      );
      console.log(`👤 Bidder: ${bid.bidder}`);
      console.log(`📦 Remaining Count: ${bid.remaining_count}`);
      console.log(`⏰ Expires: ${bid.expires_at || "No expiration"}`);
      console.log(`🆔 Bid ID: ${bid.id}`);
    } else {
      console.log("❌ No active collection bids found");
    }
  } catch (error) {
    console.error("❌ Failed to fetch bid info:", error.message);
  }

  console.log("\n");
}

/**
 * Demo 4: Batch liquidation analysis
 */
async function demoBatchLiquidationAnalysis(nftIds) {
  console.log("📈 Demo 4: Batch Liquidation Analysis");
  console.log("=".repeat(50));

  const results = [];

  for (const nftId of nftIds) {
    try {
      const info = await getLiquidationInfo(nftId);
      results.push({
        nftId,
        ...info,
      });
    } catch (error) {
      results.push({
        nftId,
        canLiquidate: false,
        error: error.message,
      });
    }
  }

  // Sort by liquidation opportunity (bid/floor ratio)
  const liquidatable = results
    .filter((r) => r.canLiquidate)
    .sort(
      (a, b) =>
        b.liquidationData.bidToFloorRatio - a.liquidationData.bidToFloorRatio,
    );

  console.log(`📊 Analyzed ${nftIds.length} NFTs:`);
  console.log(`✅ Liquidatable: ${liquidatable.length}`);
  console.log(`❌ Not liquidatable: ${results.length - liquidatable.length}`);

  if (liquidatable.length > 0) {
    console.log("\n🎯 Best liquidation opportunities:");
    liquidatable.slice(0, 3).forEach((item, index) => {
      console.log(
        `${index + 1}. ${item.nft.name} - ${item.liquidationData.bidToFloorRatio.toFixed(1)}% (${item.liquidationData.highestBidPrice.toFixed(4)} SUI)`,
      );
    });
  }

  console.log("\n");
}

/**
 * Main demo function
 */
async function runDemo() {
  console.log("🚀 Instant Sell Liquidation Demo");
  console.log("=".repeat(80));
  console.log("This demo shows how to use the instant sell functionality");
  console.log(
    "Note: This is a demonstration - no actual transactions are executed\n",
  );

  // Get command line arguments
  const nftId = process.argv[2];
  const walletAddress = process.argv[3];

  if (!nftId || !walletAddress) {
    console.log("Usage: node demo-instant-sell.js [nft-id] [wallet-address]");
    console.log(
      "Example: node demo-instant-sell.js 123e4567-e89b-12d3-a456-426614174000 0x1234...",
    );
    console.log(
      "\nAlternatively, you can modify the EXAMPLE_* constants in this file\n",
    );

    // Use example values for demo
    console.log("🎭 Running with example values...\n");
    await demoWithExampleData();
    return;
  }

  // Run demos with provided data
  await demoLiquidationAnalysis(nftId);
  await demoPrepareInstantSell(nftId, walletAddress);

  // Get collection ID from NFT for collection bid info
  try {
    const nft = await getNftInfo(nftId);
    if (nft) {
      await demoCollectionBidInfo(nft.collection_id);
    }
  } catch (error) {
    console.log("⚠️ Could not fetch collection info for collection bid demo");
  }
}

/**
 * Demo with example data (when no arguments provided)
 */
async function demoWithExampleData() {
  console.log("📚 Functionality Overview:");
  console.log("1. getLiquidationInfo() - Analyze if an NFT can be liquidated");
  console.log("2. instantSell() - Prepare instant sell transaction");
  console.log(
    "3. instantSellWithKeypair() - Execute instant sell automatically",
  );
  console.log("4. getHighestCollectionBid() - Get best available bid");
  console.log("5. getNftInfo() - Get NFT details");

  console.log("\n💡 Key Features:");
  console.log("✅ Automatic highest bid detection");
  console.log("✅ Ownership verification");
  console.log("✅ Minimum price protection");
  console.log("✅ Detailed liquidation analysis");
  console.log("✅ Batch processing support");
  console.log("✅ Transaction preparation without execution");
  console.log("✅ Automated execution with keypair");

  console.log("\n🔧 Integration Examples:");

  console.log("\n// Basic instant sell preparation:");
  console.log(`const result = await instantSell(nftId, walletAddress);`);
  console.log(`if (result.success) {`);
  console.log(`  // Use result.transaction with your wallet`);
  console.log(`}`);

  console.log("\n// Automated liquidation:");
  console.log(`const result = await instantSellWithKeypair(nftId, keypair, {`);
  console.log(`  minPriceInSui: 100 // Minimum acceptable price`);
  console.log(`});`);

  console.log("\n// Liquidation analysis:");
  console.log(`const info = await getLiquidationInfo(nftId);`);
  console.log(`if (info.canLiquidate) {`);
  console.log(
    `  console.log(\`Can sell for \${info.liquidationData.highestBidPrice} SUI\`);`,
  );
  console.log(`}`);
}

// Run the demo
runDemo().catch(console.error);
