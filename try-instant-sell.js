// Simple instant sell test script
import { instantSell, getLiquidationInfo } from "./instant-sell.js";

async function tryInstantSell() {
  const nftId = process.argv[2];
  const walletAddress = process.argv[3];

  if (!nftId || !walletAddress) {
    console.log("Usage: node try-instant-sell.js [nft-id] [wallet-address]");
    process.exit(1);
  }

  console.log("=== Attempting Instant Sell ===");

  // First, check liquidation info
  console.log("1. Analyzing liquidation opportunity...");
  const info = await getLiquidationInfo(nftId);

  if (!info.canLiquidate) {
    console.log("❌ Cannot liquidate:", info.reason || info.error);
    return;
  }

  console.log(
    `✅ Can liquidate for ${info.liquidationData.highestBidPrice.toFixed(4)} SUI`,
  );
  console.log(
    `📊 Bid is ${info.liquidationData.bidToFloorRatio.toFixed(1)}% of floor price`,
  );

  // Attempt instant sell with retry logic
  console.log("\n2. Creating instant sell transaction...");

  let result;
  const maxRetries = 3;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    console.log(`Attempt ${attempt}/${maxRetries}...`);
    result = await instantSell(nftId, walletAddress);

    if (result.success) {
      break;
    } else if (result.error.includes("504") && attempt < maxRetries) {
      console.log("⏳ API timeout, retrying in 2 seconds...");
      await new Promise((resolve) => setTimeout(resolve, 2000));
    } else {
      break;
    }
  }

  if (result.success) {
    console.log("✅ SUCCESS! Transaction ready:");
    console.log(`💰 Selling: ${result.nft.name}`);
    console.log(`💵 Price: ${result.bid.price.toFixed(4)} SUI`);
    console.log(`👤 Buyer: ${result.bid.bidder}`);
    console.log(
      "📄 Transaction prepared - you can now sign it with your wallet",
    );

    // The transaction object is in result.transaction
    // You would pass this to your wallet for signing
    console.log("🔗 Transaction object available in result.transaction");
  } else {
    console.log("❌ FAILED after all retries:", result.error);

    // Show what we can do despite the API issue
    console.log(
      "\n💡 Even though transaction creation failed, we have all the data:",
    );
    console.log(`📄 Bid ID: ${info.liquidationData.bidId}`);
    console.log(
      `💰 Price: ${info.liquidationData.highestBidPrice.toFixed(4)} SUI`,
    );
    console.log(`👤 Bidder: ${info.liquidationData.bidder}`);
    console.log(
      "🔗 You could manually accept this bid on the Tradeport website",
    );
  }
}

tryInstantSell().catch(console.error);
