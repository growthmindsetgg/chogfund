"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

// SSR-safe mobile gate: on the marketing route "/", phones go straight to the
// dApp at "/app". The viewport check runs only after mount (never during SSR /
// render), so there's no window access on the server. The explainer markup is
// hidden on mobile (md: breakpoints) so it never flashes before this fires.
export function MobileRedirect({ to = "/app", query = "(max-width: 767px)" }: { to?: string; query?: string }) {
  const router = useRouter();
  useEffect(() => {
    if (typeof window === "undefined") return;
    if (window.matchMedia(query).matches) router.replace(to);
  }, [router, to, query]);
  return null;
}
