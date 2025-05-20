import { useState, useEffect } from "react";
import {
  useCurrentAccount,
  useSignAndExecuteTransaction,
} from "@mysten/dapp-kit";
import { KioskClient, Network, KioskTransaction } from "@mysten/kiosk";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

const suiClient = new SuiClient({ url: getFullnodeUrl("mainnet") });
const kioskClient = new KioskClient({
  client: suiClient as any,
  network: Network.MAINNET,
});

const ShowNfts: React.FC = () => {
  const currentAccount = useCurrentAccount();
  const { mutate: signAndExecuteTransaction } = useSignAndExecuteTransaction();

  const [policy, setPolicy] = useState(null);
  const [kioskOwnerCaps, setKioskOwnerCaps] = useState<any[]>([]);
  const [kioskIds, setKioskIds] = useState<any[]>([]);
  const [kioskItems, setKioskItems] = useState<any[]>([]);
  const [selectedItem, setSelectedItem] = useState<any>(null);
  const [loading, setLoading] = useState(false);


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

  const call_protocol = async (item, kiosk, kioskOwnerCap, min_price, policy) => {
    alert("Inside");
    const itemType = item.type;
    const tx = new Transaction();
    const [coin] = tx.splitCoins(tx.gas, [0]);
    alert("Here");
    tx.moveCall({
      target: '0x0fd6bbeba119bca082decbcb0e4a5a5f362c69992a2931f9689ab8e269d53115::souk::transfer_nft_to_protocol',
      arguments: [kiosk, kioskOwnerCap, item.id, 0, coin, policy, tx.object("0xe9be25972bf038ef400883e06da119248b73201e78c0710495388b689effc168")],
      typeArguments: [itemType],
    });

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
  }

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
        setKioskIds(response.kioskIds)

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

  async function fetchPolicy() {
    try {
      const rawPolicies = await kioskClient.getTransferPolicies({
        type: "0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::suifrens::SuiFren<0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::capy::Capy>",
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
              (item) =>
                item.data?.display?.data?.image_url
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

          const rawPolicies = fetchPolicy();
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
        <button onClick={() => call_protocol(selectedItem, kioskIds[0], kioskOwnerCaps[0], 0, policy)}>
          Send To Protocol
        </button>
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
                    onClick={() => setSelectedItem(item)}
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
                {/* <button
                  onClick={(e) => {
                    e.stopPropagation();
                    transferToAdress(item);
                  }}
                  style={{
                    marginTop: "1rem",
                    padding: "0.5rem 1rem",
                    backgroundColor: "#4F46E5",
                    color: "#fff",
                    border: "none",
                    borderRadius: "0.5rem",
                    fontWeight: "600",
                    cursor: "pointer",
                    width: "100%",
                    transition: "background-color 0.3s ease",
                  }}
                  onMouseOver={(e) =>
                    ((e.target as HTMLElement).style.backgroundColor =
                      "#4338CA")
                  }
                  onMouseOut={(e) =>
                    ((e.target as HTMLElement).style.backgroundColor =
                      "#4F46E5")
                  }
                >
                  Transfer NFT
                </button> */}
              </div>
            </div>
          ))}
          {selectedItem && (
                  <div>{selectedItem.objectId}</div>
                )}
        </div>
      )}
    </div>
  );
};

export default ShowNfts;
