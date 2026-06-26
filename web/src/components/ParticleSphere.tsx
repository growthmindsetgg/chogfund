"use client";

import { useEffect, useRef } from "react";

// ParticleSphere — decorative fibonacci-distributed sphere of dots with a slow
// Y-axis rotation, drawn on a lightweight <canvas> (no 3D lib). Depth controls
// per-dot size + alpha so it reads as a rotating 3D sphere.
//
// IMPORTANT: this is PURE DECORATION for the pre-connect hero. It is NOT an
// "agent working" indicator — that live-status sphere is a separate task and
// must be wired to real agent state, never faked here.
//
// Accessibility: when prefers-reduced-motion is set, it renders a single static
// frame (no animation loop). Perf: ~460 dots, dpr capped at 2, rAF paused when
// the tab is hidden.

interface Props {
  /** number of dots (kept modest for low-end devices) */
  count?: number;
  /** dot color — match the surface it sits on */
  color?: string;
  /** seconds for one full rotation */
  period?: number;
  className?: string;
}

const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

export function ParticleSphere({
  count = 460,
  color = "#836EF9",
  period = 42,
  className = "",
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    // Unit-sphere points via the fibonacci spiral (even distribution).
    const pts: { x: number; y: number; z: number }[] = [];
    for (let i = 0; i < count; i++) {
      const y = 1 - (i / (count - 1)) * 2;       // 1 → -1
      const r = Math.sqrt(Math.max(0, 1 - y * y));
      const theta = i * GOLDEN_ANGLE;
      pts.push({ x: Math.cos(theta) * r, y, z: Math.sin(theta) * r });
    }

    const dpr = Math.min(2, typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1);
    let cssSize = 0;

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      cssSize = Math.max(1, Math.min(rect.width, rect.height));
      canvas.width = Math.round(cssSize * dpr);
      canvas.height = Math.round(cssSize * dpr);
    };
    resize();

    const draw = (angle: number) => {
      const w = canvas.width;
      const h = canvas.height;
      ctx.clearRect(0, 0, w, h);
      const cx = w / 2;
      const cy = h / 2;
      const radius = (Math.min(w, h) / 2) * 0.86;
      const cosA = Math.cos(angle);
      const sinA = Math.sin(angle);
      const baseDot = Math.max(0.8, radius * 0.012);

      for (let i = 0; i < pts.length; i++) {
        const p = pts[i];
        // rotate about Y
        const x = p.x * cosA + p.z * sinA;
        const z = -p.x * sinA + p.z * cosA;
        const depth = (z + 1) / 2;                 // 0 (back) → 1 (front)
        const px = cx + x * radius;
        const py = cy + p.y * radius;
        const size = baseDot * (0.5 + depth * 0.9);
        // Purple dots on the light page: keep a visible back-alpha floor (~0.3)
        // so far dots read lighter but never vanish; front dots are crisp/opaque.
        ctx.globalAlpha = 0.3 + depth * 0.7;
        ctx.beginPath();
        ctx.arc(px, py, size, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    };

    const reduceMotion =
      typeof window !== "undefined" &&
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    let raf = 0;
    let start = 0;
    const omega = (Math.PI * 2) / (period * 1000); // rad per ms

    if (reduceMotion) {
      // single static frame, tilted slightly so it doesn't look flat
      draw(0.6);
    } else {
      const loop = (t: number) => {
        if (!start) start = t;
        draw((t - start) * omega);
        raf = requestAnimationFrame(loop);
      };
      raf = requestAnimationFrame(loop);
    }

    const onResize = () => {
      resize();
      if (reduceMotion) draw(0.6);
    };
    const onVis = () => {
      if (reduceMotion) return;
      if (document.hidden) {
        cancelAnimationFrame(raf);
      } else {
        start = 0;
        raf = requestAnimationFrame((t) => {
          start = t;
          const loop = (tt: number) => {
            draw((tt - start) * omega);
            raf = requestAnimationFrame(loop);
          };
          raf = requestAnimationFrame(loop);
        });
      }
    };

    window.addEventListener("resize", onResize);
    document.addEventListener("visibilitychange", onVis);

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", onResize);
      document.removeEventListener("visibilitychange", onVis);
    };
  }, [count, color, period]);

  return (
    <canvas
      ref={canvasRef}
      aria-hidden
      className={`block h-full w-full ${className}`}
    />
  );
}
