// Typed re-exports of the contract ABIs. The raw JSON imports lose literal
// types, so wagmi/viem can't infer them as `Abi`. Cast once here, import the
// typed names everywhere else.

import type { Abi } from "viem";

// ---- P4 allocator set (active — P8 repoint) ----
import allocatorRaw    from "@abis/AllocatorVault.json";
import lpManagerRaw    from "@abis/LpManager.json";
import vaultRouterRaw  from "@abis/VaultRouter.json";
import healthRaw       from "@abis/HealthMonitor.json";
import pythReaderRaw   from "@abis/PythPriceReader.json";
import logBookRaw      from "@abis/LogBook.json";
import usdcRaw         from "@abis/MockUSDC.json";

export const allocatorAbi:     Abi = allocatorRaw   as unknown as Abi;
export const lpManagerAbi:     Abi = lpManagerRaw   as unknown as Abi;
export const vaultRouterAbi:   Abi = vaultRouterRaw as unknown as Abi;
export const healthMonitorAbi: Abi = healthRaw      as unknown as Abi;
export const pythReaderAbi:    Abi = pythReaderRaw  as unknown as Abi;
export const logBookAbi:       Abi = logBookRaw     as unknown as Abi;
export const usdcAbi:          Abi = usdcRaw        as unknown as Abi;

// ---- Legacy P1 set (retired — kept so pre-P8 components compile until STEP 2) ----
import vaultRaw from "@abis/RebalanceVault.json";
import ammRaw   from "@abis/OracleAMM.json";

export const vaultAbi: Abi = vaultRaw as unknown as Abi;
export const ammAbi:   Abi = ammRaw   as unknown as Abi;
