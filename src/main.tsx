import React from "react";
import ReactDOM from "react-dom/client";
import "@mysten/dapp-kit/dist/index.css";
import "@radix-ui/themes/styles.css";

import { SuiClientProvider, WalletProvider } from "@mysten/dapp-kit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Theme } from "@radix-ui/themes";
import App from "./App.tsx";
import { networkConfig } from "./networkConfig.ts";

import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { KioskClient, Network } from "@mysten/kiosk";

const client = new SuiClient({ url: getFullnodeUrl("mainnet") });
const kioskClient = new KioskClient({ client, network: Network.MAINNET });

const queryClient = new QueryClient();

async function init() {
  try {
    console.log("Test");
    const policies = await kioskClient.getTransferPolicies({
      type:
        "0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::suifrens::SuiFren<0xee496a0cc04d06a345982ba6697c90c619020de9e274408c7819f787ff66e1a1::capy::Capy>",
    });

    if (policies.length === 0) {
      console.log("No transfer policy found for this type");
    } else {
      const policy = policies[0];
      console.log("TransferPolicy ID:", policy.id);
    }
  } catch (error) {
    console.error("Error fetching transfer policies:", error);
  }

  // Mount React app AFTER the async code runs
  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <Theme appearance="dark">
        <QueryClientProvider client={queryClient}>
          <SuiClientProvider networks={networkConfig} defaultNetwork="testnet">
            <WalletProvider autoConnect>
              <App />
            </WalletProvider>
          </SuiClientProvider>
        </QueryClientProvider>
      </Theme>
    </React.StrictMode>
  );
}

init(); // Call the async init function
