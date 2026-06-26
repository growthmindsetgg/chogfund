"use client";

import * as React from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, lightTheme } from "@rainbow-me/rainbowkit";
import { Toaster } from "sonner";
import { config } from "@/wagmi";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Avoid hammering Ankr on focus storms; explicit refetchInterval per hook.
      refetchOnWindowFocus: true,
      retry: (failureCount, error) => {
        const msg = error instanceof Error ? error.message : String(error);
        // Back off once on 429, then give up — the periodic interval picks it up.
        if (msg.includes("429") || msg.toLowerCase().includes("rate")) return failureCount < 1;
        return failureCount < 2;
      },
      staleTime: 8_000,
    },
  },
});

const rkTheme = lightTheme({
  accentColor: "#836EF9",
  accentColorForeground: "#FFFFFF",
  borderRadius: "large",
  fontStack: "system",
});

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={rkTheme} modalSize="compact" coolMode={false}>
          {children}
          <Toaster
            position="top-right"
            richColors
            theme="light"
            toastOptions={{ style: { fontFamily: "var(--font-inter)" } }}
          />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
