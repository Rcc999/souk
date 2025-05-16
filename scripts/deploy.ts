import { execSync } from 'child_process';
import { SuiClient, getFullnodeUrl } from '@mysten/sui.js/client';
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { TransactionBlock } from '@mysten/sui.js/transactions';
import { fromB64 } from '@mysten/sui.js/utils';

// Connect to local network
const client = new SuiClient({ url: getFullnodeUrl('localnet') });

async function deploy() {
    try {
        // Build the package
        console.log('Building package...');
        execSync('sui move build', { stdio: 'inherit' });

        // Deploy the package
        console.log('Deploying package...');
        const { modules, dependencies } = JSON.parse(
            execSync('sui client publish --gas-budget 100000000 --json').toString()
        );

        const tx = new TransactionBlock();
        const [upgradeCap] = tx.publish({
            modules,
            dependencies,
        });

        // Create royalty reserve
        const [reserve] = tx.moveCall({
            target: `${packageId}::counter::create_royalty_reserve`,
            arguments: [],
        });

        // Execute the transaction
        const result = await client.signAndExecuteTransactionBlock({
            signer: keypair,
            transactionBlock: tx,
            options: {
                showEffects: true,
                showEvents: true,
            },
        });

        console.log('Deployment successful!');
        console.log('Package ID:', result.effects?.created?.[0]?.reference?.objectId);
        console.log('Reserve ID:', result.effects?.created?.[1]?.reference?.objectId);
        
        return {
            packageId: result.effects?.created?.[0]?.reference?.objectId,
            reserveId: result.effects?.created?.[1]?.reference?.objectId,
        };
    } catch (error) {
        console.error('Deployment failed:', error);
        throw error;
    }
}

// Run the deployment
deploy().then(console.log).catch(console.error); 