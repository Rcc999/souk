import { ConnectButton, useCurrentAccount } from "@mysten/dapp-kit";
import { isValidSuiObjectId } from "@mysten/sui/utils";
import { Box, Container, Flex, Heading, Separator } from "@radix-ui/themes";
import { useState } from "react";
import { Counter } from "./Counter";
import { CreateCounter } from "./CreateCounter";
import { LendingActions } from "./LendingActions";

function App() {
  const currentAccount = useCurrentAccount();
  const [counterId, setCounter] = useState(() => {
    const hash = window.location.hash.slice(1);
    return isValidSuiObjectId(hash) ? hash : null;
  });

  return (
    <>
      <Flex
        position="sticky"
        px="4"
        py="2"
        justify="between"
        style={{
          borderBottom: "1px solid var(--gray-a2)",
        }}
      >
        <Box>
          <Heading>dApp Starter Template</Heading>
        </Box>

        <Box>
          <ConnectButton />
        </Box>
      </Flex>
      <Container>
        <Container
          mt="5"
          pt="2"
          px="4"
          style={{ background: "var(--gray-a2)", minHeight: 500 }}
        >
          {currentAccount ? (
            <>
              {counterId ? (
                <Counter id={counterId} />
              ) : (
                <CreateCounter
                  onCreated={(id) => {
                    window.location.hash = id;
                    setCounter(id);
                  }}
                />
              )}
              <Separator my="4" size="4" />
              <Heading mb="2">NFT Lending Protocol Actions</Heading>
              <LendingActions />
            </>
          ) : (
            <Heading>Please connect your wallet</Heading>
          )}
        </Container>
      </Container>
    </>
  );
}

export default App;
