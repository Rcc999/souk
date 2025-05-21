import React, { useState, useEffect } from "react";
import {
  useCurrentAccount,
  useSignAndExecuteTransaction,
} from "@mysten/dapp-kit";
import {
  KioskClient,
  Network,
  KioskTransaction,
  TransferPolicy,
} from "@mysten/kiosk";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

declare global {
  interface Window {
    __alreadyAlerted?: boolean;
  }
}

const suiClient = new SuiClient({ url: "https://sui-rpc.publicnode.com" });
const kioskClient = new KioskClient({
  client: suiClient as any,
  network: Network.MAINNET,
});

const ShowNfts: React.FC = () => {
  const currentAccount = useCurrentAccount();
  const { mutate: signAndExecuteTransaction } = useSignAndExecuteTransaction();
  const [isError, setIsError] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const [policy, setPolicy] = useState<TransferPolicy[] | null>(null);
  const [kioskOwnerCaps, setKioskOwnerCaps] = useState<any[]>([]);
  const [kioskIds, setKioskIds] = useState<string[]>([]);
  const [kioskItems, setKioskItems] = useState<any[]>([]);
  const [selectedItem, setSelectedItem] = useState<any>(null);
  const [selectedItemPolicy, setSelectedItemPolicy] = useState<
    TransferPolicy[] | null
  >(null);
  const [loading, setLoading] = useState(false);

  const clearError = () => {
    setIsError(false);
    setErrorMessage(null);
  };

  const showError = (message: string) => {
    setIsError(true);
    setErrorMessage(message);
    // Auto-clear error after 5 seconds
    setTimeout(clearError, 5000);
  };

  const transferMonies = async () => {
    setLoading(true);
    try {
      if (!currentAccount?.address) {
        console.error("No wallet connected");
        return;
      }

      const address =
        "0x392fa498dbcfffc5cb8b0b3d8bf43f5621f0f75632c5507da0fc66601faa1a46";

      const tx = new Transaction();
      // Use the first gas object that has enough balance
      const [coin] = tx.splitCoins(tx.gas, [100000000]);
      tx.transferObjects([coin], tx.pure.address(address));

      await signAndExecuteTransaction(
        {
          transaction: tx,
          chain: "sui:mainnet",
        },
        {
          onSuccess: (result) => {
            console.log("Transaction successful:", result);
          },
          onError: (error) => {
            console.error("Transaction failed:", error);
          },
        },
      );
    } catch (e) {
      console.error("Error in transferMonies:", e);
    } finally {
      setLoading(false);
    }
  };

  const call_protocol = async () => {
    try {
      if (!selectedItem) {
        showError("Please select an NFT first.");
        return;
      }
      if (!currentAccount?.address) {
        showError("Wallet not connected.");
        return;
      }

      const {
        objectId: nft_id,
        type: itemType,
        kioskId: itemKioskId,
      } = selectedItem;

      if (!itemKioskId) {
        showError("Selected item is not associated with a kiosk.");
        return;
      }

      if (!itemType) {
        showError("Selected item has no type information.");
        console.error("Item type is missing:", selectedItem);
        return;
      }

      // Ensure we have a valid type string
      let fullType: string;
      try {
        fullType =
          typeof itemType === "string" ? itemType : itemType.toString();
        if (!fullType || fullType.trim() === "") {
          throw new Error("Empty type string");
        }
      } catch (e) {
        showError("Invalid item type format");
        console.error("Failed to process item type:", itemType, e);
        return;
      }

      console.log("Using item type:", fullType);

      const kioskIndex = kioskIds.findIndex((id) => id === itemKioskId);
      if (kioskIndex === -1) {
        showError(
          "Could not find the kiosk owner cap for the selected item's kiosk.",
        );
        return;
      }
      const kioskOwnerCap = kioskOwnerCaps[kioskIndex] as any;

      if (!kioskOwnerCap) {
        showError("Kiosk owner cap is invalid for the selected item.");
        console.error("Invalid kioskOwnerCap:", kioskOwnerCap);
        return;
      }

      // Use the KioskOwnerCap from the kioskOwnerCaps array
      const cap = kioskOwnerCaps[kioskIndex];
      if (!cap || !cap.objectId || !cap.version || !cap.digest) {
        showError("Could not find a valid KioskOwnerCap for this kiosk.");
        console.error("Invalid cap from kioskOwnerCaps:", cap);
        return;
      }
      const capRef = {
        objectId: cap.objectId,
        version: cap.version,
        digest: cap.digest,
      };
      console.log("KioskOwnerCap objectRef (from owned cap):", capRef);

      const tx = new Transaction();
      const [coin] = tx.splitCoins(tx.gas, [0]);

      const policyIdToUse =
        selectedItemPolicy &&
        selectedItemPolicy.length > 0 &&
        selectedItemPolicy[0]?.id
          ? selectedItemPolicy[0].id
          : "0x6";

      console.log("Using policy ID:", policyIdToUse);

      tx.moveCall({
        target:
          "0x0fd6bbeba119bca082decbcb0e4a5a5f362c69992a2931f9689ab8e269d53115::souk::transfer_nft_to_protocol",
        arguments: [
          tx.object(itemKioskId),
          tx.objectRef(capRef),
          tx.object(nft_id),
          tx.pure.u64(0),
          coin,
          tx.object(policyIdToUse),
          tx.object(
            "0xe9be25972bf038ef400883e06da119248b73201e78c0710495388b689effc168",
          ),
        ],
        typeArguments: [fullType],
      });

      await signAndExecuteTransaction(
        {
          transaction: tx,
          chain: "sui:mainnet",
        },
        {
          onSuccess: (result) => {
            console.log("Transfer to protocol successful:", result);
            showError("NFT successfully sent to protocol!");
            setSelectedItem(null);
            setSelectedItemPolicy(null);
            fetchAllKioskItems();
          },
          onError: (error) => {
            console.error("Transfer to protocol failed:", error);
            const errorMsg =
              (error as any)?.shape?.message ||
              error?.message ||
              "Unknown error occurred";
            showError(`Transfer failed: ${errorMsg}`);
          },
        },
      );
    } catch (e: any) {
      console.error("Error in call_protocol (catch block):", e);
      showError(`An error occurred: ${e.message || e.toString()}`);
    }
  };

  const fetchKioskIds = async () => {
    const address = currentAccount?.address;

    try {
      let allKioskIds: string[] = [];
      let hasNextPage = true;
      let cursor: string | null = null;

      while (hasNextPage) {
        const response = await kioskClient.getOwnedKiosks({
          address: address || "",
          pagination: {
            limit: 50,
            cursor: cursor ?? undefined,
          },
        });

        setKioskOwnerCaps(response.kioskOwnerCaps);
        setKioskIds(response.kioskIds as string[]);

        allKioskIds = [...allKioskIds, ...response.kioskIds];

        if (response.hasNextPage && response.nextCursor) {
          cursor = response.nextCursor;
        } else {
          hasNextPage = false;
        }
      }

      return allKioskIds;
    } catch (error) {
      console.error("Error fetching owned Kiosks:", error);
    }
  };

  async function fetchPolicyForItem(itemType: string) {
    try {
      const rawPolicies = await kioskClient.getTransferPolicies({
        type: itemType,
      });

      return rawPolicies;
    } catch (error) {
      console.error("Error fetching transfer policies:", error);
      return null;
    }
  }

  const fetchAllKioskItems = async () => {
    if (!currentAccount?.address) {
      return;
    }

    setLoading(true);
    try {
      const kioskIds = await fetchKioskIds();
      if (!kioskIds || kioskIds.length === 0) {
        return;
      }

      setKioskItems([]); // Clear existing items while loading
      let allItems: any[] = [];

      for (const kioskId of kioskIds || []) {
        try {
          const kiosk = await kioskClient.getKiosk({
            id: kioskId.toString(),
            options: {
              withKioskFields: true,
              withListingPrices: true,
              withObjects: true,
            },
          });

          alert(kiosk.items);
          const objects = kiosk.items || [];
          if (objects.length > 0) {
            // Filter out items without proper display data
            const validItems = objects.filter(
              (item) => item.data?.display?.data?.image_url,
              // && item.data?.display?.data?.name,
            );
            allItems = allItems.concat(
              validItems.map((item) => ({
                ...item,
                kioskId,
                isListed: kiosk.listingIds?.includes(item.objectId) || false,
              })),
            );
          }

          alert(allItems);

          const rawPolicies = await fetchPolicyForItem(
            "0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::suifrens::SuiFren<0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::capy::Capy>",
          );
          setPolicy(rawPolicies);
        } catch (kioskError) {
          console.error(`Error fetching kiosk ${kioskId}:`, kioskError);
          // Continue with other kiosks even if one fails
        }
      }

      if (allItems.length === 0) {
        console.log("No items found in your kiosks");
      } else {
        setKioskItems(allItems);
      }
    } catch (e) {
      console.error("Error loading kiosk items:", e);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ padding: "2rem" }}>
      {isError && errorMessage && (
        <div
          style={{
            position: "fixed",
            top: "1rem",
            right: "1rem",
            padding: "1rem",
            backgroundColor: "#FEE2E2",
            border: "1px solid #EF4444",
            borderRadius: "0.5rem",
            color: "#991B1B",
            zIndex: 1000,
            maxWidth: "80%",
            boxShadow: "0 2px 4px rgba(0,0,0,0.1)",
          }}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
            }}
          >
            <span>{errorMessage}</span>
            <button
              onClick={clearError}
              style={{
                marginLeft: "1rem",
                padding: "0.25rem 0.5rem",
                backgroundColor: "#EF4444",
                color: "white",
                border: "none",
                borderRadius: "0.25rem",
                cursor: "pointer",
              }}
            >
              ×
            </button>
          </div>
        </div>
      )}
      <div style={{ display: "flex", gap: "1rem", marginBottom: "2rem" }}>
        <button
          style={{
            padding: "0.5rem 1rem",
            backgroundColor: "#4F46E5",
            color: "#fff",
            border: "none",
            borderRadius: "0.5rem",
            fontWeight: "600",
            cursor: "pointer",
            boxShadow: "0 2px 6px rgba(0, 0, 0, 0.15)",
            transition: "background-color 0.3s ease",
          }}
          onMouseOver={(e) =>
            ((e.target as HTMLElement).style.backgroundColor = "#4338CA")
          }
          onMouseOut={(e) =>
            ((e.target as HTMLElement).style.backgroundColor = "#4F46E5")
          }
          onClick={() => fetchAllKioskItems()}
        >
          {loading ? "Loading..." : "Show My NFTs"}
        </button>

        <button
          style={{
            padding: "0.5rem 1rem",
            backgroundColor: "#10B981",
            color: "#fff",
            border: "none",
            borderRadius: "0.5rem",
            fontWeight: "600",
            cursor: "pointer",
            boxShadow: "0 2px 6px rgba(0, 0, 0, 0.15)",
            transition: "background-color 0.3s ease",
          }}
          onMouseOver={(e) =>
            ((e.target as HTMLElement).style.backgroundColor = "#059669")
          }
          onMouseOut={(e) =>
            ((e.target as HTMLElement).style.backgroundColor = "#10B981")
          }
          onClick={() => transferMonies()}
        >
          Transfer Money
        </button>
        <button onClick={call_protocol}>Send To Protocol</button>
      </div>
      {kioskItems.length > 0 && (
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))",
            gap: "2rem",
            padding: "1rem",
          }}
        >
          {kioskItems.map((item) => (
            <div
              key={item.objectId}
              style={{
                border: "1px solid #e5e7eb",
                borderRadius: "0.75rem",
                overflow: "hidden",
                boxShadow: "0 4px 6px -1px rgba(0, 0, 0, 0.1)",
                transition: "transform 0.2s ease",
                backgroundColor: "white",
                cursor: "pointer",
              }}
              onMouseOver={(e) => {
                e.currentTarget.style.transform = "translateY(-4px)";
              }}
              onMouseOut={(e) => {
                e.currentTarget.style.transform = "translateY(0)";
              }}
              onClick={async () => {
                setSelectedItem(item);
                setSelectedItemPolicy(null); // Reset policy while fetching
                if (item.type) {
                  const fetchedPolicy = await fetchPolicyForItem(item.type);
                  console.log(
                    "Fetched policy for:",
                    item.data?.display?.data?.name || item.objectId,
                    fetchedPolicy,
                  );
                  setSelectedItemPolicy(fetchedPolicy);
                } else {
                  console.error(
                    "Item type is missing for policy fetching.",
                    item,
                  );
                  setSelectedItemPolicy([]); // Indicate no policy or error
                }
              }}
            >
              {item.data?.display?.data?.image_url && (
                <div
                  style={{
                    width: "100%",
                    height: "250px",
                    position: "relative",
                  }}
                >
                  <img
                    src={item.data.display.data.image_url}
                    alt={item.data.display.data.name || "NFT"}
                    style={{
                      width: "100%",
                      height: "100%",
                      objectFit: "cover",
                    }}
                  />
                </div>
              )}
              <div style={{ padding: "1rem" }}>
                <h3
                  style={{
                    margin: "0",
                    fontSize: "1.1rem",
                    fontWeight: "600",
                    color: "#1f2937",
                  }}
                >
                  {item.data?.display?.data?.name || "Unnamed NFT"}
                </h3>
                {item.data?.display?.data?.description && (
                  <p
                    style={{
                      margin: "0.5rem 0 0",
                      fontSize: "0.875rem",
                      color: "#6b7280",
                      display: "-webkit-box",
                      WebkitLineClamp: 2,
                      WebkitBoxOrient: "vertical",
                      overflow: "hidden",
                    }}
                  >
                    {item.data.display.data.description}
                  </p>
                )}
              </div>
            </div>
          ))}
          {selectedItem && <div>Selected Item ID: {selectedItem.objectId}</div>}
          {selectedItemPolicy && (
            <div
              style={{
                marginTop: "1rem",
                padding: "1rem",
                border: "1px solid #ccc",
                borderRadius: "0.5rem",
                backgroundColor: "#f9f9f9",
              }}
            >
              <h4>Transfer Policy for Selected Item:</h4>
              {selectedItemPolicy.length > 0 ? (
                <pre>{JSON.stringify(selectedItemPolicy, null, 2)}</pre>
              ) : (
                <p>No transfer policies found or item type is missing.</p>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
};

export default ShowNfts;
