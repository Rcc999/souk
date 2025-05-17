import { ConnectButton, useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { isValidSuiObjectId } from "@mysten/sui/utils";
import { Box, Container, Flex, Heading, Separator } from "@radix-ui/themes";
import { useState, useEffect } from "react";

import { KioskClient, Network, KioskTransaction } from "@mysten/kiosk";
import { Transaction } from "@mysten/sui/transactions";


import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";


const client = new SuiClient({ url: "https://fullnode.mainnet.sui.io:443" });
const kioskClient = new KioskClient({ client, network: Network.MAINNET });


function App() {
  const { mutate: signAndExecuteTransaction } = useSignAndExecuteTransaction();
  const [digest, setDigest] = useState('');

  const currentAccount = useCurrentAccount();
  const [kioskOwnerCaps, setKioskOwnerCaps] = useState([]);
  

  const [kioskItems, setKioskItems] = useState([]);

  const [selectedItem, setSelectedItem] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [policies, setPolicies] = useState(null);
  const [policyObjects, setPolicyObjects] = useState<any[]>([]);
  

  useEffect(() => {
    async function fetchAllKioskItems() {
      if (!currentAccount?.address) return;
      setLoading(true);
      setError(null);
      try {
        alert("Starting...")
        const { kioskIds, kioskOwnerCaps } = await kioskClient.getOwnedKiosks({ address: currentAccount.address });
        
        setKioskOwnerCaps(kioskOwnerCaps);

        alert(`Found ${kioskOwnerCaps.length} kiosks.`)

        let allItems = [];
        for (const kioskId of kioskIds) {
          const kiosk = await kioskClient.getKiosk({
            id: kioskId,
            options: { withKioskFields: true, withListingPrices: true, withObjects: true },
          });
          if (kiosk.items) {
            alert(`Found ${kiosk.items.length} items in this kiosk.`)
            allItems = allItems.concat(kiosk.items.map((item) => ({ ...item, kioskId })));
          }
        }

        setKioskItems(allItems);
      } catch (e) {
        console.error("Error loading kiosk items", e);
        setError("Failed to load kiosk items.");
      }
    }

    fetchAllKioskItems();
  }, [currentAccount]);

  useEffect(() => {
    async function fetchPolicy() {
      if (!kioskItems.length) return;
      alert("Before Fetched");
      const rawPolicies = await kioskClient.getTransferPolicies({
        type:
          "0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::suifrens::SuiFren<0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::capy::Capy>",
      });


      const fullObjects = rawPolicies;
      
      alert(fullObjects);
      setPolicyObjects(fullObjects);
    }

    for (const item of kioskItems) {
      alert(item.type);
    }

    fetchPolicy();
    setLoading(false);

  }, [kioskItems])

  async function resetAll() {
    setKioskOwnerCaps([]);
    setKioskItems([]);
    setSelectedItem(null);
    setLoading(false);
    setPolicies(null);
    setPolicyObjects([]);

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
          Sui Kiosk Viewer
        </h1>
  
        <div style={{ marginBottom: "2rem" }}>
          <ConnectButton />
        </div>
        <button onClick={() => resetAll()}>Reset</button>
  
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
      {loading ? (
        <p>Loading policies...</p>
      ) : policyObjects.length === 0 ? (
        <p>No transfer policies found.</p>
      ) : (
        policyObjects.map((obj, idx) => (
          <pre key={idx}>{JSON.stringify(obj, null, 2)}</pre>
        ))
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
                <p><strong>Kiosk ID:</strong> {item.kioskId}</p>
                <p><strong>Item ID:</strong> {item.objectId}</p>
                <p><strong>Type:</strong> {item.type}</p>
                {/* {item.kioskId && (<button onClick={() => {WithdrawFromKiosk(currentAccount, item?.kioskId)}}>Withdraw From Kiosk</button>)} */}
                
                {cap && (
                  <button onClick={() => signMessageWithWallet(currentAccount, "Hey")}>
                    Withdraw From Kiosk
                  </button>
                )}
              </div>
            );
          })}


        </div>
      </div>
    </div>
  );
  
}

// function test(kioskOwnerCaps, signAndExecuteTransaction) {
//   const tx = new Transaction();
//   const kioskTx = new KioskTransaction({ transaction: tx, kioskClient: kioskClient, cap: kioskOwnerCaps[0]})
//   const item = kioskTx.take({
//     itemType: "0xcfe2d87aa5712b67cad2732edb6a2201bfdf592377e5c0968b7cb02099bd8e21::ve_sca::VeScaKey",
//     itemId: "0x61e28225ba7031935a132a5364d67aa1ab4044b2a1996bd16df6292e2aeaafa9"
//   });
  
//   // Now transfer the item to yourself (or another address)
//   // tx.transferObjects([item], currentAccount.address);
//   kioskTx.place({
//     itemType: "0xcfe2d87aa5712b67cad2732edb6a2201bfdf592377e5c0968b7cb02099bd8e21::ve_sca::VeScaKey",
//     item: item
//   });

//   kioskTx.finalize();
//   signAndExecuteTransaction(
//     {
//       transaction: tx,
//       chain: "sui:mainnet"
//     },
//     {
//       onSuccess: (result) => {
//         alert(result);
//       },
//     },
//   );
// }


export default App;
