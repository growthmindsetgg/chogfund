import type { ReactNode } from "react";

// Minimal, dependency-free markdown renderer for the whitepaper. Supports the
// subset the doc uses: # / ## / ### headings, **bold**, *italic*, `code`,
// "- " bullet lists, "1." numbered lists, --- rules, and blank-line paragraphs.

function renderInline(text: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(\*\*([^*]+)\*\*|\*([^*]+)\*|`([^`]+)`)/g;
  let last = 0;
  let k = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[2] !== undefined) out.push(<strong key={k++} className="font-bold text-[var(--text)]">{m[2]}</strong>);
    else if (m[3] !== undefined) out.push(<em key={k++}>{m[3]}</em>);
    else if (m[4] !== undefined) out.push(<code key={k++} className="rounded bg-[var(--purple-soft)] px-1.5 py-0.5 font-mono text-[0.85em] text-[var(--purple-strong)]">{m[4]}</code>);
    last = re.lastIndex;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ source }: { source: string }) {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const blocks: ReactNode[] = [];
  let para: string[] = [];
  let list: { ordered: boolean; items: string[] } | null = null;
  let key = 0;

  const flushPara = () => {
    if (para.length) {
      blocks.push(<p key={key++} className="leading-relaxed text-[var(--text-muted)]">{renderInline(para.join(" "))}</p>);
      para = [];
    }
  };
  const flushList = () => {
    if (list) {
      const items = list.items.map((it, i) => (
        <li key={i} className="leading-relaxed text-[var(--text-muted)]">{renderInline(it)}</li>
      ));
      blocks.push(
        list.ordered
          ? <ol key={key++} className="ml-5 list-decimal space-y-1.5">{items}</ol>
          : <ul key={key++} className="ml-5 list-disc space-y-1.5">{items}</ul>,
      );
      list = null;
    }
  };

  for (const raw of lines) {
    const line = raw.trimEnd();
    const t = line.trim();
    if (t === "") { flushPara(); flushList(); continue; }

    if (t.startsWith("### ")) { flushPara(); flushList(); blocks.push(<h3 key={key++} className="mt-7 text-lg font-bold text-[var(--text)]">{renderInline(t.slice(4))}</h3>); continue; }
    if (t.startsWith("## "))  { flushPara(); flushList(); blocks.push(<h2 key={key++} className="mt-9 text-2xl font-extrabold tracking-tight text-[var(--blue)]">{renderInline(t.slice(3))}</h2>); continue; }
    if (t.startsWith("# "))   { flushPara(); flushList(); blocks.push(<h1 key={key++} className="text-3xl font-black tracking-tight text-[var(--blue)]">{renderInline(t.slice(2))}</h1>); continue; }
    if (/^-{3,}$/.test(t))    { flushPara(); flushList(); blocks.push(<hr key={key++} className="my-7 border-[var(--border)]" />); continue; }

    const ol = t.match(/^(\d+)\.\s+(.*)$/);
    if (t.startsWith("- "))   { flushPara(); if (!list || list.ordered) { flushList(); list = { ordered: false, items: [] }; } list.items.push(t.slice(2)); continue; }
    if (ol)                   { flushPara(); if (!list || !list.ordered) { flushList(); list = { ordered: true, items: [] }; } list.items.push(ol[2]); continue; }

    flushList();
    para.push(t);
  }
  flushPara();
  flushList();

  return <div className="space-y-3">{blocks}</div>;
}
