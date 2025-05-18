import { ConnectButton, useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { isValidSuiObjectId } from "@mysten/sui/utils";
import { Box, Container, Flex, Heading, Separator } from "@radix-ui/themes";
import { useState, useEffect } from "react";

import { KioskClient, Network, KioskTransaction } from "@mysten/kiosk";
import { Transaction } from "@mysten/sui/transactions";


import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";


const client = new SuiClient({ url: getFullnodeUrl("testnet") });
const kioskClient = new KioskClient({ client, network: Network.TESTNET });


function App() {
  const { mutate: signAndExecuteTransaction } = useSignAndExecuteTransaction();

  const currentAccount = useCurrentAccount();
  const [kioskOwnerCaps, setKioskOwnerCaps] = useState([]);

  const [kioskItems, setKioskItems] = useState([]);

  const [selectedItem, setSelectedItem] = useState(null);

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  async function delistWithPurchaseCap(item, kioskOwnerCap) {
    const itemType = item.type;
    const tx = new Transaction();

    const kioskTx = new KioskTransaction({ transaction: tx, kioskClient, cap: kioskOwnerCap });

    const purchase_cap = tx.object("0xb4c31f763c328928144266e3e2668b9ba0cfbe968f1708cc4cd06b6c3cebb287");

    tx.moveCall({
      target: '0x2::kiosk::return_purchase_cap',
      arguments: [kioskTx.getKiosk(), purchase_cap],
      typeArguments: [itemType],
    });

    kioskTx.finalize();

    signAndExecuteTransaction(
          {
            transaction: tx,
            chain: "sui:devnet"
          },
          {
            onSuccess: (result) => {
              alert(result);
            },
          },
        );
  }
  
  async function listWithPurchaseCap(item, cap) {
    setLoading(true);
    setError(null);
    try {
      const itemType = item.type;
      const address = '0x392fa498dbcfffc5cb8b0b3d8bf43f5621f0f75632c5507da0fc66601faa1a46';
      const tx = new Transaction();
      const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(100)]);
      tx.transferObjects([coin], tx.pure.address(address));
      signAndExecuteTransaction(
            {
              transaction: tx,
              chain: "sui:testnet"
            },
            {
              onSuccess: (result) => {
                alert(result);
              },
            },
          );
    alert("TX Executed.");
    } catch (e) {
      setError('Failed to list item with purchase cap.');
      alert(e);
      console.error(e);
    } finally {
      setLoading(false);
    }
  }
  

  async function fetchAllKioskItems() {
    if (!currentAccount?.address) return;
    setLoading(true);
    setError(null);
    try {
      const { kioskIds, kioskOwnerCaps } = await kioskClient.getOwnedKiosks({ address: currentAccount.address });
      setKioskOwnerCaps(kioskOwnerCaps);

      let allItems = [];
      for (const kioskId of kioskIds) {
        const kiosk = await kioskClient.getKiosk({
          id: kioskId,
          options: { withKioskFields: true, withListingPrices: true, withObjects: true },
        });
        if (kiosk.items) {
          allItems = allItems.concat(kiosk.items.map((item) => ({ ...item, kioskId })));
        }
      }

      setKioskItems(allItems);
      setLoading(false);
    } catch (e) {
      console.error("Error loading kiosk items", e);
      setError("Failed to load kiosk items.");
    }
  }

  return (
    <div style={{
      display: "flex",
      justifyContent: "center",
      padding: "2rem",
      backgroundColor: "#0f172a", // dark background
      minHeight: "100vh"
    }}>
      <div style={{
        maxWidth: "1000px",
        width: "100%",
        color: "white",
        textAlign: "center",
      }}>
        <h1 style={{
          marginBottom: "1.5rem",
          fontSize: "2.5rem",
          fontWeight: "bold"
        }}>
          Souk Lending
        </h1>

        
        <div style={{ position: "absolute", top: "1rem", right: "1rem" }}>
          <ConnectButton />
        </div>

        {!kioskItems.length && (<button
          style={{
            padding: "0.5rem 1rem",
            backgroundColor: "#4F46E5", // Indigo-600
            color: "#fff",
            border: "none",
            borderRadius: "0.5rem",
            fontWeight: "600",
            cursor: "pointer",
            boxShadow: "0 2px 6px rgba(0, 0, 0, 0.15)",
            transition: "background-color 0.3s ease",
          }}
          onMouseOver={(e) => (e.target.style.backgroundColor = "#4338CA")} // Indigo-700
          onMouseOut={(e) => (e.target.style.backgroundColor = "#4F46E5")}
          onClick={() => fetchAllKioskItems()}
        >
          Show My NFTs
        </button>)}

  
        {loading && (
          <p style={{ marginTop: "2rem", fontSize: "1.2rem" }}>
            ⏳ Loading kiosk items...
          </p>
        )}
        {error && (
          <p style={{ color: "#ff6b6b", marginTop: "1rem", fontWeight: "bold" }}>
            {error}
          </p>
        )}
        {!loading && kioskItems.length === 0 && currentAccount && !error && (
          <p style={{ marginTop: "2rem", fontSize: "1.1rem", opacity: 0.85 }}>
            🧐 No kiosk items found for your account.
          </p>
        )}
  
        <div style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fill, minmax(280px, 1fr))",
          gap: "1.5rem",
          justifyContent: "center",
          marginTop: "2rem",
        }}>
          {kioskItems.map((item) => {
            const isSelected = selectedItem?.objectId === item.objectId;
            const cap = kioskOwnerCaps.find(cap => cap.kioskId === item.kioskId);
            const url = item.data.display.data.image_url;
            const name = item.data.display.data.name;
            return (
              <div
                key={item.objectId}
                onClick={() => setSelectedItem(item)}
                style={{
                  border: isSelected ? "2px solid #38bdf8" : "1px solid #334155",
                  borderRadius: "12px",
                  padding: "1rem",
                  background: isSelected ? "#e0f2fe" : "#1e293b",
                  color: isSelected ? "#0f172a" : "white",
                  cursor: "pointer",
                  boxShadow: isSelected
                    ? "0 0 10px rgba(56, 189, 248, 0.5)"
                    : "0 2px 6px rgba(0,0,0,0.2)",
                  transition: "all 0.2s ease-in-out",
                }}
              >
                <img src={url}></img>
                {/* <div>{name}</div>
                <p><strong>Kiosk ID:</strong> {item.kioskId}</p>
                <p><strong>Item ID:</strong> {item.objectId}</p>
                <p><strong>Item Type:</strong> {item.type}</p> */}

        
                {/* {item.kioskId && (<button onClick={() => {WithdrawFromKiosk(currentAccount, item?.kioskId)}}>Withdraw From Kiosk</button>)} */}
                
                {cap  && (
                  <div>
                  <button
                    onClick={() =>
                      listWithPurchaseCap(item, cap) // Use the first policy for demo
                    }
                  >
                    List With Purchase Cap
                  </button>

                  {/* <button
                  onClick={() =>
                    delistWithPurchaseCap(item, cap) // Use the first policy for demo
                  }
                  >
                  DeList With Purchase Cap
                  </button> */}
                  </div>
                )}


              </div>
            );
          })}
        </div>
          {selectedItem && ( () => {
            const cap = kioskOwnerCaps.find(cap => cap.kioskId === selectedItem.kioskId);
            return (
            <button
            style={{
              padding: "0.5rem 1rem",
              backgroundColor: "#4F46E5", // Indigo-600
              color: "#fff",
              border: "none",
              borderRadius: "0.5rem",
              fontWeight: "600",
              cursor: "pointer",
              boxShadow: "0 2px 6px rgba(0, 0, 0, 0.15)",
              transition: "background-color 0.3s ease",
            }}
            onMouseOver={(e) => (e.target.style.backgroundColor = "#4338CA")} // Indigo-700
            onMouseOut={(e) => (e.target.style.backgroundColor = "#4F46E5")}
            >
          Deposit {selectedItem.data.display.data.name}
        </button>
            )
        }
          )}
      </div>
    </div>
  );
 
}


export default App;
