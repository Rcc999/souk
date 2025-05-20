import React from "react";
import { ConnectButton } from "@mysten/dapp-kit";
import ShowNfts from "./components/ShowNfts";

const App: React.FC = () => {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "center",
        padding: "2rem",
        backgroundColor: "#0f172a", // dark background
        minHeight: "100vh",
      }}
    >
      <div
        style={{
          maxWidth: "1000px",
          width: "100%",
          color: "white",
          textAlign: "center",
        }}
      >
        <h1
          style={{
            marginBottom: "1.5rem",
            fontSize: "2.5rem",
            fontWeight: "bold",
          }}
        >
          Souk Lending
        </h1>

        <div style={{ position: "absolute", top: "1rem", right: "1rem" }}>
          <ConnectButton />
        </div>
        <ShowNfts />
      </div>
    </div>
  );
};

export default App;
