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

  let soukCap = "0x1024b764329d6b7690aef7cff72e8257a6323a66de7dc3c785b48917804f7eb7";
  let contractsAddress = "0xa834c3485e0980bf2a9aae2f5bc8eff77a46b1cd2aba9ccfb11e19863a12db90";
  let chain = "mainnet" // Used for signAndExecute

  const currentAccount = useCurrentAccount();
  const { mutate: signAndExecuteTransaction } = useSignAndExecuteTransaction();
  const [isError, setIsError] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const [kioskOwnerCaps, setKioskOwnerCaps] = useState<any[]>([]);
  const [kioskIds, setKioskIds] = useState<string[]>([]);
  const [kioskItems, setKioskItems] = useState<any[]>([]);
  const [selectedItem, setSelectedItem] = useState<any>(null);
  const [selectedItemPolicy, setSelectedItemPolicy] = useState<
  TransferPolicy[] | null
  >(null);
  const [loading, setLoading] = useState(false);
  const [loanTickets, setLoanTickets] = useState<any[]>([]);
  const [selectedTicket, setSelectedTicket] = useState<any>(null);
  
  function extractGenericType(typeStr: string): string | null {
    const match = typeStr.match(/<(.+)>/);
    return match ? match[1] : null;
  }

  
  async function fetchAllTickets() {
    try {
      const baseType = contractsAddress+"::souk::LoanTicket";
  
      const allObjects = await suiClient.getOwnedObjects({
        owner: currentAccount?.address,
        options: { 
          showType: true,
          showContent: true
        }
      });
  
      const filteredObjects = allObjects.data.filter(obj => {
        const objType = obj.data?.type;
        return objType?.startsWith(baseType + "<");
      });
  
      setLoanTickets(filteredObjects);
    } catch (error) {
      console.error("Error fetching owned objects:", error);
      return [];
    }
  }
  
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

  const exchange_ticket = async () => {
    const tx = new Transaction();
    const [coin] = tx.splitCoins(tx.gas, [0]);

    let typeToUse = extractGenericType(selectedTicket.data.content.type);

    tx.moveCall({
      target:
        contractsAddress+"::souk::redeem_nft",
      arguments: [
        tx.object(selectedTicket.data.objectId), // Loan Ticket
        tx.object(selectedTicket.data.content.fields.transfer_policy_id), // Policy
        tx.object(soukCap), // SoukCap
        tx.object(selectedTicket.data.content.fields.borrower_kiosk_id), // borrower_kiosk
        tx.object(selectedTicket.data.content.fields.borrower_kiosk_cap_id), // borrower_kiosk
        coin,
      ],
      typeArguments: [typeToUse],
    });

    await signAndExecuteTransaction(
      {
        transaction: tx,
        chain: "sui:"+chain,
      },
      {
        onSuccess: (result) => {
          console.log("Transfer to protocol successful:", result);
          showError("NFT successfully sent to protocol!");
          setSelectedTicket(null);
          setSelectedItem(null);
          setSelectedItemPolicy(null);
          setLoanTickets([]);
          fetchAllTickets();
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
    )
  }

  const deposite_nft = async () => {
    try {

      const {
        objectId: nft_id,
        type: itemType,
        kioskId: itemKioskId,
      } = selectedItem;

      const kioskIndex = kioskIds.findIndex((id) => id === itemKioskId);

      // Use the KioskOwnerCap from the kioskOwnerCaps array
      const cap = kioskOwnerCaps[kioskIndex];
      const capRef = {
        objectId: cap.objectId,
        version: cap.version,
        digest: cap.digest,
      };

      const tx = new Transaction();
      const [coin] = tx.splitCoins(tx.gas, [0]);

      const policyIdToUse =
        selectedItemPolicy &&
        selectedItemPolicy.length > 0 &&
        selectedItemPolicy[0]?.id
          ? selectedItemPolicy[0].id
          : "0x6";

      tx.moveCall({
        target:
          contractsAddress+"::souk::transfer_nft_to_protocol",
        arguments: [
          tx.object(itemKioskId),
          tx.objectRef(capRef),
          tx.object(nft_id),
          tx.pure.u64(0),
          coin,
          tx.object(policyIdToUse),
          tx.object(soukCap),
        ],
        typeArguments: [itemType],
      });

      await signAndExecuteTransaction(
        {
          transaction: tx,
          chain: "sui:"+chain,
        },
        {
          onSuccess: (_) => {
            showError("NFT successfully sent to protocol!");
            setSelectedTicket(null);
            setSelectedItem(null);
            setSelectedItemPolicy(null);
            setKioskIds([]);
            setKioskItems([]);
            fetchAllKioskItems();
          },
          onError: (error) => {
            const errorMsg =
              (error as any)?.shape?.message ||
              error?.message ||
              "Unknown error occurred";
            showError(`Transfer failed: ${errorMsg}`);
          },
        },
      );
    } catch (e: any) {
      showError(`An error occurred: ${e.message || e.toString()}`);
    }
  };

  const buttonStyle = (bg: string, hover: string) => ({
    padding: "0.5rem 1rem",
    backgroundColor: bg,
    color: "#fff",
    border: "none",
    borderRadius: "0.5rem",
    fontWeight: 600,
    cursor: "pointer",
    boxShadow: "0 2px 6px rgba(0,0,0,0.15)",
    transition: "background-color 0.3s ease",
    onMouseEnter: (e: any) => (e.target.style.backgroundColor = hover),
    onMouseLeave: (e: any) => (e.target.style.backgroundColor = bg),
  });
  

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

          const objects = kiosk.items || [];
          if (objects.length > 0) {
            // Filter out items without proper display data
            const validItems = objects;
            allItems = allItems.concat(
              validItems.map((item) => ({
                ...item,
                kioskId,
                isListed: kiosk.listingIds?.includes(item.objectId) || false,
              })),
            );
          }

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

  return (<div style={{ padding: "2rem" }}>
    {isError && errorMessage && (
      <div
        style={{
          position: "fixed",
          top: "1rem",
          right: "1rem",
          padding: "1rem 1.5rem",
          backgroundColor: "#FEE2E2",
          border: "1px solid #EF4444",
          borderRadius: "0.5rem",
          color: "#991B1B",
          zIndex: 1000,
          maxWidth: "400px",
          boxShadow: "0 4px 12px rgba(0,0,0,0.1)",
          transition: "transform 0.2s ease, opacity 0.2s ease",
        }}
      >
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            gap: "1rem",
          }}
        >
          <span style={{ flex: 1 }}>{errorMessage}</span>
          <button
            onClick={clearError}
            style={{
              backgroundColor: "transparent",
              color: "#991B1B",
              fontSize: "1.2rem",
              border: "none",
              cursor: "pointer",
              fontWeight: "bold",
            }}
          >
            ×
          </button>
        </div>
      </div>
    )}
  
    {/* Action Buttons */}
    <div style={{ display: "flex", gap: "1rem", marginBottom: "2rem", flexWrap: "wrap" }}>
      <button
        style={buttonStyle("#4F46E5", "#4338CA")}
        onClick={() => fetchAllKioskItems()}
      >
        {loading ? "Loading..." : "Show My NFTs"}
      </button>
      <button
  style={buttonStyle("#6366F1", "#4F46E5")}
  onClick={() => fetchAllTickets()}
>
  {loading ? "Loading..." : "Show LoanTicket"}
</button>

{selectedItem && (
      <button
        style={buttonStyle("#F59E0B", "#D97706")}
        onClick={deposite_nft}
      >
        Deposit NFT
      </button>
)}

{selectedTicket && (
  <button
  style={buttonStyle("#10B981", "#059669")}
  onClick={() => exchange_ticket()}
>
  Exchange Ticket Against NFT
</button>
)}
    </div>

    {loanTickets.length > 0 && (
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))",
          gap: "2rem",
        }}
      >
        {loanTickets.map((item) => (
          <div
            key={item.objectId}
            style={{
              border: "1px solid #e5e7eb",
              borderRadius: "0.75rem",
              backgroundColor: "white",
              boxShadow: "0 4px 6px rgba(0, 0, 0, 0.1)",
              cursor: "pointer",
              transition: "transform 0.2s",
            }}
            onMouseOver={(e) => (e.currentTarget.style.transform = "translateY(-4px)")}
            onMouseOut={(e) => (e.currentTarget.style.transform = "translateY(0)")}
            onClick={async () => {
              setSelectedTicket(item);
            }}
          >
            <div style={{ padding: "1rem" }}>
              <h3 style={{ fontSize: "1.1rem", margin: 0, fontWeight: 600, color: "#111827" }}>
                {item.data?.objectId || "Unnamed NFT"}
              </h3>
            </div>
          </div>
        ))}
      </div>
    )}
  
    {/* NFT Grid */}
    {kioskItems.length > 0 && (
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))",
          gap: "2rem",
        }}
      >
        {kioskItems.map((item) => (
          <div
            key={item.objectId}
            style={{
              border: "1px solid #e5e7eb",
              borderRadius: "0.75rem",
              backgroundColor: "white",
              boxShadow: "0 4px 6px rgba(0, 0, 0, 0.1)",
              cursor: "pointer",
              transition: "transform 0.2s",
            }}
            onMouseOver={(e) => (e.currentTarget.style.transform = "translateY(-4px)")}
            onMouseOut={(e) => (e.currentTarget.style.transform = "translateY(0)")}
            onClick={async () => {
              setSelectedItem(item);
              setSelectedItemPolicy(null);
              if (item.type) {
                const fetchedPolicy = await fetchPolicyForItem(item.type);
                setSelectedItemPolicy(fetchedPolicy);
              } else {
                setSelectedItemPolicy([]);
              }
            }}
          >
            {item.data?.display?.data?.image_url && (
              <div style={{ width: "100%", height: "200px", overflow: "hidden" }}>
                <img
                  src={item.data.display.data.image_url}
                  alt={item.data.display.data.name || "NFT"}
                  style={{ width: "100%", height: "100%", objectFit: "cover" }}
                />
              </div>
            )}
            <div style={{ padding: "1rem" }}>
              <h3 style={{ fontSize: "1.1rem", margin: 0, fontWeight: 600, color: "#111827" }}>
                {item.data?.display?.data?.name || "Unnamed NFT"}
              </h3>
              {item.data?.display?.data?.description && (
                <p
                  style={{
                    marginTop: "0.5rem",
                    fontSize: "0.875rem",
                    color: "#6B7280",
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
      </div>
    )}
  
    {/* Selected Policy */}
    {selectedItemPolicy && (
      <div
        style={{
          marginTop: "2rem",
          padding: "1rem",
          border: "1px solid #d1d5db",
          borderRadius: "0.5rem",
          backgroundColor: "#F9FAFB",
        }}
      >
        <h4 style={{ marginBottom: "0.5rem", color: "#374151" }}>
          Transfer Policy for Selected Item:
        </h4>
        {selectedItemPolicy.length > 0 ? (
          <pre style={{ fontSize: "0.875rem", color: "#111827", overflowX: "auto" }}>
            {JSON.stringify(selectedItemPolicy, null, 2)}
          </pre>
        ) : (
          <p style={{ color: "#6B7280" }}>No transfer policies found or item type is missing.</p>
        )}
      </div>
    )}

{selectedTicket && (
      <div
        style={{
          marginTop: "2rem",
          padding: "1rem",
          border: "1px solid #d1d5db",
          borderRadius: "0.5rem",
          backgroundColor: "#F9FAFB",
        }}
      >
        <h4 style={{ marginBottom: "0.5rem", color: "#374151" }}>
          Transfer Policy for Selected Item:
        </h4>
        
          <pre style={{ fontSize: "0.875rem", color: "#111827", overflowX: "auto" }}>
            {JSON.stringify(selectedTicket, null, 2)}
          </pre>
      </div>
    )}
  </div>
  )
};

export default ShowNfts;
