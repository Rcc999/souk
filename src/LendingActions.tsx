import { useState, useEffect } from "react";
import { Box, Button, Flex, Text, TextField, Heading } from "@radix-ui/themes";
import {
  useCurrentAccount,
  useSignAndExecuteTransaction,
  useSuiClient,
} from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { KioskClient, Network, KioskOwnerCap } from "@mysten/kiosk";

// TODO: Replace with your actual deployed Package ID
const LENDING_PACKAGE_ID = "0xYOUR_LENDING_PACKAGE_ID";
// TODO: Replace with your actual LendingProtocolStore object ID
const LENDING_PROTOCOL_STORE_ID = "0xYOUR_LENDING_PROTOCOL_STORE_ID";

// TODO: Consider moving SuiClient and KioskClient to a context or a service hook
// const suiClient = new SuiClient({ url: getFullnodeUrl("testnet") }); // Remove old client
// const kioskClient = new KioskClient({ // Will initialize kioskClient differently
//   client: suiClient,
//   network: Network.TESTNET, // Or Mainnet/Devnet
//   // For devnet/localnet, you might need to provide packageIds for kiosk rules if not using Mysten's standard deployment
// });

export function LendingActions() {
  const currentAccount = useCurrentAccount();
  const { mutate: signAndExecuteTransaction } = useSignAndExecuteTransaction();
  const suiClient = useSuiClient(); // Get SuiClient from dapp-kit context

  // State for Deposit NFT
  const [depositNftId, setDepositNftId] = useState("");
  const [depositNftType, setDepositNftType] = useState("");
  // Kiosk details will be fetched if possible, but keeping manual as fallback for now
  const [borrowerKioskId, setBorrowerKioskId] = useState("");
  const [borrowerKioskCapId, setBorrowerKioskCapId] = useState("");
  const [isFetchingKiosk, setIsFetchingKiosk] = useState(false);

  // State for Repay Royalty
  const [repayNftId, setRepayNftId] = useState("");
  const [repayAmount, setRepayAmount] = useState(""); // Amount in MIST

  // Initialize KioskClient inside the component or a useEffect, once suiClient is available
  const [kioskClient, setKioskClient] = useState<KioskClient | null>(null);

  useEffect(() => {
    // Initialize KioskClient once suiClient is available
    setKioskClient(
      new KioskClient({
        client: suiClient as any, // Cast to any as a temporary workaround for type mismatch
        network: Network.TESTNET, // Or Mainnet/Devnet
      }),
    );
  }, [suiClient]);

  const tryFetchKioskDetails = async () => {
    if (!currentAccount || !kioskClient) return; // Ensure kioskClient is initialized
    setIsFetchingKiosk(true);
    try {
      const { kioskOwnerCaps } = await kioskClient.getOwnedKiosks({
        address: currentAccount.address,
      });
      if (kioskOwnerCaps.length > 0) {
        const firstKioskCap = kioskOwnerCaps[0];
        setBorrowerKioskId(firstKioskCap.kioskId);
        setBorrowerKioskCapId(firstKioskCap.objectId);
        console.log("Fetched Kiosk ID:", firstKioskCap.kioskId);
        console.log("Fetched Kiosk Cap ID:", firstKioskCap.objectId);
      } else {
        alert("No Kiosks found for your account.");
      }
    } catch (error) {
      console.error("Error fetching kiosk details:", error);
      alert("Failed to fetch kiosk details.");
    } finally {
      setIsFetchingKiosk(false);
    }
  };

  useEffect(() => {
    if (currentAccount && kioskClient) {
      // Ensure kioskClient is initialized
      tryFetchKioskDetails();
    }
  }, [currentAccount, kioskClient]); // Add kioskClient to dependency array

  const handleDepositNft = async () => {
    if (
      !currentAccount ||
      !LENDING_PACKAGE_ID ||
      !LENDING_PROTOCOL_STORE_ID ||
      !depositNftId ||
      !depositNftType ||
      !borrowerKioskId ||
      !borrowerKioskCapId
    ) {
      alert(
        "Please connect wallet and fill all deposit fields (Kiosk ID and Cap ID might auto-fill if found).",
      );
      return;
    }
    if (
      LENDING_PACKAGE_ID === "0xYOUR_LENDING_PACKAGE_ID" ||
      LENDING_PROTOCOL_STORE_ID === "0xYOUR_LENDING_PROTOCOL_STORE_ID"
    ) {
      alert("Please replace placeholder Package ID and Store ID in the code.");
      return;
    }

    const txb = new Transaction();
    txb.moveCall({
      target: `${LENDING_PACKAGE_ID}::nft_lending::borrower_deposit_nft_permission`,
      typeArguments: [depositNftType],
      arguments: [
        txb.object(LENDING_PROTOCOL_STORE_ID),
        txb.object(borrowerKioskId),
        txb.object(borrowerKioskCapId),
        txb.pure.address(depositNftId),
      ],
    });

    signAndExecuteTransaction(
      {
        transaction: txb,
      },
      {
        onSuccess: (result) => {
          console.log("Deposit NFT successful:", result);
          alert(`NFT Deposit Permissioned! Digest: ${result.digest}`);
        },
        onError: (error: Error) => {
          console.error("Deposit NFT error:", error);
          alert(`Error depositing NFT: ${error.message}`);
        },
      },
    );
  };

  const handleRepayRoyalty = async () => {
    if (
      !currentAccount ||
      !LENDING_PACKAGE_ID ||
      !LENDING_PROTOCOL_STORE_ID ||
      !repayNftId ||
      !repayAmount
    ) {
      alert(
        "Please connect wallet and fill all repay fields, including correct Package and Store IDs.",
      );
      return;
    }
    if (
      LENDING_PACKAGE_ID === "0xYOUR_LENDING_PACKAGE_ID" ||
      LENDING_PROTOCOL_STORE_ID === "0xYOUR_LENDING_PROTOCOL_STORE_ID"
    ) {
      alert("Please replace placeholder Package ID and Store ID in the code.");
      return;
    }
    const repayAmountInt = parseInt(repayAmount, 10);
    if (isNaN(repayAmountInt) || repayAmountInt <= 0) {
      alert("Please enter a valid positive number for repay amount.");
      return;
    }

    const txb = new Transaction();
    const [paymentCoin] = txb.splitCoins(txb.gas, [
      txb.pure.u64(repayAmountInt),
    ]);

    txb.moveCall({
      target: `${LENDING_PACKAGE_ID}::nft_lending::reimburse_royalty_payment`,
      arguments: [
        txb.object(LENDING_PROTOCOL_STORE_ID),
        txb.pure.address(repayNftId),
        paymentCoin,
      ],
    });

    signAndExecuteTransaction(
      {
        transaction: txb,
      },
      {
        onSuccess: (result) => {
          console.log("Repay Royalty successful:", result);
          alert(`Royalty Repaid! Digest: ${result.digest}`);
        },
        onError: (error: Error) => {
          console.error("Repay Royalty error:", error);
          alert(`Error repaying royalty: ${error.message}`);
        },
      },
    );
  };

  if (!currentAccount) {
    return <Text>Please connect your wallet to use lending features.</Text>;
  }

  return (
    <Flex direction="column" gap="4" mt="4">
      <Box>
        <Heading size="4">Deposit NFT for Lending</Heading>
        <Button
          onClick={tryFetchKioskDetails}
          disabled={isFetchingKiosk || !kioskClient}
          my="2"
        >
          {isFetchingKiosk
            ? "Fetching Kiosk..."
            : "Reload/Fetch My Kiosk Details"}
        </Button>
        <TextField.Root my="2">
          <input
            placeholder="NFT Object ID to deposit"
            value={depositNftId}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setDepositNftId(e.target.value)
            }
            style={{ padding: "8px", width: "100%" }}
          />
        </TextField.Root>
        <TextField.Root my="2">
          <input
            placeholder="NFT Type (e.g., 0xPKG::module::NftName)"
            value={depositNftType}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setDepositNftType(e.target.value)
            }
            style={{ padding: "8px", width: "100%" }}
          />
        </TextField.Root>
        <Text size="2" color="gray">
          Your Kiosk Details (auto-fetched):
        </Text>
        <TextField.Root my="2">
          <input
            placeholder="Your Kiosk ID (auto-fetched or manual)"
            value={borrowerKioskId}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setBorrowerKioskId(e.target.value)
            }
            disabled={isFetchingKiosk}
            style={{ padding: "8px", width: "100%" }}
          />
        </TextField.Root>
        <TextField.Root my="2">
          <input
            placeholder="Your Kiosk Owner Cap ID (auto-fetched or manual)"
            value={borrowerKioskCapId}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setBorrowerKioskCapId(e.target.value)
            }
            disabled={isFetchingKiosk}
            style={{ padding: "8px", width: "100%" }}
          />
        </TextField.Root>
        <Button onClick={handleDepositNft} disabled={!kioskClient} my="2">
          Permission NFT Deposit
        </Button>
      </Box>

      <Box my="4">
        <Heading size="4">Repay Royalty to Protocol</Heading>
        <TextField.Root my="2">
          <input
            placeholder="NFT Object ID for royalty repayment"
            value={repayNftId}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setRepayNftId(e.target.value)
            }
            style={{ padding: "8px", width: "100%" }}
          />
        </TextField.Root>
        <TextField.Root my="2">
          <input
            placeholder="Royalty Amount (in MIST)"
            type="number"
            value={repayAmount}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
              setRepayAmount(e.target.value)
            }
            style={{ padding: "8px", width: "100%" }}
          />
        </TextField.Root>
        <Button onClick={handleRepayRoyalty} disabled={!kioskClient} my="2">
          Repay Royalty
        </Button>
      </Box>
    </Flex>
  );
}
