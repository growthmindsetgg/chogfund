"use client";

import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center whitespace-nowrap rounded-xl text-sm font-semibold transition-colors disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-none",
  {
    variants: {
      variant: {
        primary: "bg-[var(--purple)] text-white hover:bg-[var(--purple-strong)] shadow-sm",
        secondary: "bg-[var(--purple-soft)] text-[var(--purple-strong)] hover:bg-[var(--purple-soft-strong)]",
        ghost: "bg-transparent text-[var(--text)] hover:bg-[var(--purple-soft)]",
        danger: "bg-[var(--rose)] text-white hover:opacity-90",
        outline: "border border-[var(--border)] bg-white text-[var(--text)] hover:bg-[var(--purple-soft)]",
      },
      size: {
        sm: "h-9 px-3",
        md: "h-11 px-4",
        lg: "h-12 px-5 text-base",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  function Button({ className, variant, size, asChild = false, ...props }, ref) {
    const Comp = asChild ? Slot : "button";
    return <Comp ref={ref} className={cn(buttonVariants({ variant, size }), className)} {...props} />;
  },
);
