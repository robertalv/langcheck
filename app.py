"""
LangCheck — desktop GUI.

Drop or open a .txt file (or paste text), click Analyze, and every stylometric
metric from analyzer.py is rendered as a card. Built on CustomTkinter so it
ships as a self-contained Mac .app via PyInstaller (see build.sh).
"""

from __future__ import annotations

import os
import threading
import traceback

import customtkinter as ctk
from tkinter import filedialog, messagebox

import analyzer

# Drag-and-drop is best-effort. The tkinterdnd2 native lib doesn't load on every
# Python/Tk build (e.g. python.org 3.13), so we (a) optionally inherit the mixin
# if the package imports, and (b) only actually enable DnD if `_require` succeeds
# at runtime. Either way the app works via the Open button + paste box.
try:
    from tkinterdnd2 import DND_FILES, TkinterDnD

    class _Root(ctk.CTk, TkinterDnD.DnDWrapper):
        pass

    _DND_IMPORTED = True
except Exception:  # pragma: no cover - depends on platform build
    _Root = ctk.CTk
    _DND_IMPORTED = False
    DND_FILES = None


ctk.set_appearance_mode("system")
ctk.set_default_color_theme("blue")

MUTED = ("gray40", "gray60")
ACCENT = ("#1f6aa5", "#2b8de0")


class LangCheckApp(_Root):
    def __init__(self):
        super().__init__()
        self.title("LangCheck — stylometric analyzer")
        self.geometry("1000x760")
        self.minsize(820, 600)

        self._source_name = None        # filename for the report header
        self._last_report_text = ""     # cached plain-text report for copy/save

        # Try to actually turn on drag-and-drop; degrade silently if the native
        # tkdnd library can't load on this platform.
        self._dnd_ok = False
        if _DND_IMPORTED:
            try:
                self.TkdndVersion = TkinterDnD._require(self)
                self._dnd_ok = True
            except Exception:
                self._dnd_ok = False

        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        self._build_header()
        self._build_controls()
        self._build_results()

        if self._dnd_ok:
            self.drop_target_register(DND_FILES)
            self.dnd_bind("<<Drop>>", self._on_drop)

        self._show_placeholder()

    # ------------------------------------------------------------------ UI --
    def _build_header(self):
        head = ctk.CTkFrame(self, corner_radius=0, fg_color=ACCENT, height=64)
        head.grid(row=0, column=0, sticky="ew")
        head.grid_propagate(False)
        ctk.CTkLabel(
            head, text="  LangCheck", font=ctk.CTkFont(size=22, weight="bold"),
            text_color="white",
        ).pack(side="left", padx=(16, 8), pady=12)
        ctk.CTkLabel(
            head, text="stylometric / forensic-linguistics text analyzer",
            font=ctk.CTkFont(size=13), text_color="white",
        ).pack(side="left", pady=12)

    def _build_controls(self):
        bar = ctk.CTkFrame(self, corner_radius=10)
        bar.grid(row=1, column=0, sticky="ew", padx=12, pady=(12, 6))
        bar.grid_columnconfigure(0, weight=1)

        # paste / drop textbox
        hint = "Drop a .txt file here, paste text below, or use “Open .txt…”." \
            if self._dnd_ok else "Paste text below, or use “Open .txt…”."
        ctk.CTkLabel(bar, text=hint, text_color=MUTED, anchor="w").grid(
            row=0, column=0, columnspan=4, sticky="ew", padx=12, pady=(10, 2))

        self.textbox = ctk.CTkTextbox(bar, height=140, wrap="word")
        self.textbox.grid(row=1, column=0, columnspan=4, sticky="ew", padx=12, pady=(0, 8))

        # options row
        opts = ctk.CTkFrame(bar, fg_color="transparent")
        opts.grid(row=2, column=0, columnspan=4, sticky="ew", padx=12, pady=(0, 4))
        opts.grid_columnconfigure(1, weight=1)

        ctk.CTkLabel(opts, text="Rarity phrase (optional):").grid(row=0, column=0, padx=(0, 6))
        self.phrase_entry = ctk.CTkEntry(
            opts, placeholder_text="e.g. the system checks out from one end to the other")
        self.phrase_entry.grid(row=0, column=1, sticky="ew", padx=(0, 12))

        self.clean_var = ctk.BooleanVar(value=False)
        ctk.CTkCheckBox(opts, text="Strip letter salutations/closings",
                        variable=self.clean_var).grid(row=0, column=2, padx=(0, 6))

        # buttons row
        btns = ctk.CTkFrame(bar, fg_color="transparent")
        btns.grid(row=3, column=0, columnspan=4, sticky="ew", padx=12, pady=(4, 10))

        ctk.CTkButton(btns, text="📂  Open .txt…", width=130,
                      command=self._open_file).pack(side="left")
        ctk.CTkButton(btns, text="Clear", width=70, fg_color="transparent",
                      border_width=1, text_color=("gray20", "gray80"),
                      command=self._clear).pack(side="left", padx=8)

        self.analyze_btn = ctk.CTkButton(
            btns, text="Analyze  ▶", width=140,
            font=ctk.CTkFont(size=14, weight="bold"), command=self._analyze)
        self.analyze_btn.pack(side="right")

        self.copy_btn = ctk.CTkButton(btns, text="Copy report", width=110,
                                      state="disabled", command=self._copy_report)
        self.copy_btn.pack(side="right", padx=8)
        self.save_btn = ctk.CTkButton(btns, text="Save report…", width=120,
                                      state="disabled", command=self._save_report)
        self.save_btn.pack(side="right")

        self.status = ctk.CTkLabel(self, text="", text_color=MUTED, anchor="w")
        self.status.grid(row=3, column=0, sticky="ew", padx=20, pady=(0, 8))

    def _build_results(self):
        self.results = ctk.CTkScrollableFrame(self, corner_radius=10,
                                              label_text="Results")
        self.results.grid(row=2, column=0, sticky="nsew", padx=12, pady=6)
        self.results.grid_columnconfigure(0, weight=1)

    # ------------------------------------------------------------- actions --
    def _open_file(self):
        path = filedialog.askopenfilename(
            title="Choose a text file",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")])
        if path:
            self._load_path(path)

    def _on_drop(self, event):
        # event.data may be "{/path with spaces}" or multiple paths
        raw = event.data.strip()
        if raw.startswith("{") and raw.endswith("}"):
            raw = raw[1:-1]
        path = raw.split("} {")[0].strip("{}")
        if os.path.isfile(path):
            self._load_path(path)

    def _load_path(self, path):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception as exc:
            messagebox.showerror("Could not read file", str(exc))
            return
        self.textbox.delete("1.0", "end")
        self.textbox.insert("1.0", text)
        self._source_name = os.path.basename(path)
        self.status.configure(text=f"Loaded: {path}")

    def _clear(self):
        self.textbox.delete("1.0", "end")
        self._source_name = None
        self.status.configure(text="")
        for w in self.results.winfo_children():
            w.destroy()
        self._show_placeholder()
        self.copy_btn.configure(state="disabled")
        self.save_btn.configure(state="disabled")

    def _analyze(self):
        text = self.textbox.get("1.0", "end").strip()
        if not text:
            messagebox.showinfo("Nothing to analyze", "Open a .txt file or paste some text first.")
            return
        self.analyze_btn.configure(state="disabled", text="Analyzing…")
        self.status.configure(text="Loading language model and analyzing…")
        phrase = self.phrase_entry.get().strip() or None
        clean = self.clean_var.get()
        threading.Thread(target=self._run_analysis, args=(text, clean, phrase),
                         daemon=True).start()

    def _run_analysis(self, text, clean, phrase):
        try:
            report = analyzer.analyze_text(text, clean=clean, rarity_phrase=phrase)
            if self._source_name:
                report["meta"]["source"] = self._source_name
            self._last_report_text = analyzer.format_report(report)
            self.after(0, self._render, report)
        except Exception:
            tb = traceback.format_exc()
            self.after(0, self._render_error, tb)

    # ------------------------------------------------------------- render --
    def _show_placeholder(self):
        card = ctk.CTkFrame(self.results, fg_color="transparent")
        card.grid(sticky="ew", padx=4, pady=20)
        ctk.CTkLabel(
            card,
            text="No results yet.\nDrop or open a .txt file, then click Analyze.",
            text_color=MUTED, font=ctk.CTkFont(size=14), justify="left",
        ).pack(anchor="w")

    def _render_error(self, tb):
        self.analyze_btn.configure(state="normal", text="Analyze  ▶")
        self.status.configure(text="Error during analysis.")
        for w in self.results.winfo_children():
            w.destroy()
        box = ctk.CTkTextbox(self.results, height=300, wrap="word")
        box.grid(sticky="nsew", padx=4, pady=4)
        box.insert("1.0", tb)

    def _render(self, report):
        self.analyze_btn.configure(state="normal", text="Analyze  ▶")
        for w in self.results.winfo_children():
            w.destroy()

        m = report["meta"]
        meta_line = f"{m['words']:,} words   ·   {m['sentences']:,} sentences   ·   {m['characters']:,} characters"
        if m.get("source"):
            meta_line += f"   ·   {m['source']}"
        self.status.configure(text=f"Done — {meta_line}")

        summary = ctk.CTkFrame(self.results, corner_radius=8)
        summary.grid(sticky="ew", padx=4, pady=(4, 8))
        ctk.CTkLabel(summary, text=meta_line, font=ctk.CTkFont(size=13, weight="bold"),
                     anchor="w").pack(anchor="w", padx=14, pady=10)

        for i, r in enumerate(report["metrics"], 1):
            self._metric_card(i, r)

        self.copy_btn.configure(state="normal")
        self.save_btn.configure(state="normal")

    def _metric_card(self, index, r):
        card = ctk.CTkFrame(self.results, corner_radius=8)
        card.grid(sticky="ew", padx=4, pady=5)
        card.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(card, text=f"{index}.  {r['title']}",
                     font=ctk.CTkFont(size=15, weight="bold"), anchor="w",
                     justify="left").grid(sticky="ew", padx=14, pady=(10, 0))

        ctk.CTkLabel(card, text=r["headline"], font=ctk.CTkFont(size=14),
                     text_color=ACCENT, anchor="w", justify="left",
                     wraplength=860).grid(sticky="ew", padx=14, pady=(2, 4))

        for ex in r["examples"]:
            ctk.CTkLabel(card, text="•  " + ex, anchor="w", justify="left",
                         wraplength=850, font=ctk.CTkFont(size=12)).grid(
                sticky="ew", padx=22, pady=1)

        if r["note"]:
            ctk.CTkLabel(card, text=r["note"], anchor="w", justify="left",
                         wraplength=860, text_color=MUTED,
                         font=ctk.CTkFont(size=11, slant="italic")).grid(
                sticky="ew", padx=14, pady=(4, 10))
        else:
            ctk.CTkLabel(card, text="").grid(pady=2)

    # --------------------------------------------------------- copy / save --
    def _copy_report(self):
        self.clipboard_clear()
        self.clipboard_append(self._last_report_text)
        self.status.configure(text="Report copied to clipboard.")

    def _save_report(self):
        path = filedialog.asksaveasfilename(
            defaultextension=".txt",
            initialfile="langcheck_report.txt",
            filetypes=[("Text files", "*.txt")])
        if path:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(self._last_report_text)
            self.status.configure(text=f"Saved: {path}")


def main():
    app = LangCheckApp()
    app.mainloop()


if __name__ == "__main__":
    main()
