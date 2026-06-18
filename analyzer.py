"""
LangCheck — stylometric / forensic-linguistics text analyzer.

Pure analysis logic (no GUI), so it can be unit-tested headless and reused.
Every metric returns a MetricResult; analyze_text() runs them all over one
document and returns a dict the GUI can render.

The metrics map 1:1 to the user's request list:

    1.  "Rather" as a degree adverb            -> metric_rather
    2.  "In" before a gerund phrase            -> metric_in_before_gerund
    3.  Contraction rate                       -> metric_contractions
    4.  "Will" vs "shall" ratio                -> metric_will_shall
    5.  Possessive determiner + gerund         -> metric_possessive_gerund
    6.  Dropped / missing article (heuristic)  -> metric_dropped_article
    7.  Complementizer inclusion vs deletion   -> metric_complementizer
    8.  "Is this" + cataphoric prompt          -> metric_is_this
    9.  Top-3 degree adverbs share             -> metric_top_degree_adverbs
    10. Phrase / word rarity (COCA-style)      -> metric_rarity  (optional)
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field, asdict
from typing import Optional

import spacy

# --------------------------------------------------------------------------- #
# Model loading (lazy, cached)
# --------------------------------------------------------------------------- #

_NLP = None


def get_nlp():
    """Load and cache the spaCy English model."""
    global _NLP
    if _NLP is None:
        _NLP = spacy.load("en_core_web_sm")
    return _NLP


# --------------------------------------------------------------------------- #
# Result container
# --------------------------------------------------------------------------- #


@dataclass
class MetricResult:
    key: str                       # short id, e.g. "rather"
    title: str                     # human title
    headline: str                  # one-line takeaway
    stats: dict = field(default_factory=dict)   # numeric details
    examples: list = field(default_factory=list)  # example sentences/matches
    note: str = ""                 # caveats / how to read it
    spans: list = field(default_factory=list)   # [[start, end], …] char offsets of hits

    def as_dict(self):
        return asdict(self)


# --------------------------------------------------------------------------- #
# Shared word lists
# --------------------------------------------------------------------------- #

# Intensifying / degree adverbs (used by metrics 1 and 9). We additionally
# verify with the parser that the token actually modifies an ADJ/ADV, which
# filters out e.g. "so" as a conjunction or "more" as a determiner.
DEGREE_ADVERBS = {
    "very", "quite", "rather", "too", "so", "extremely", "fairly", "somewhat",
    "really", "pretty", "highly", "totally", "absolutely", "completely",
    "utterly", "entirely", "slightly", "terribly", "awfully", "remarkably",
    "exceedingly", "incredibly", "particularly", "especially", "exceptionally",
    "decidedly", "mighty", "dreadfully", "frightfully", "deeply", "greatly",
    "strongly", "perfectly", "thoroughly", "wholly", "fully", "purely",
    "simply", "truly", "downright", "positively", "unusually", "uncommonly",
}

# Singular count nouns that are routinely article-less in fixed phrases, so we
# do NOT flag them as dropped articles (metric 6).
ARTICLELESS_IDIOM_NOUNS = {
    "home", "bed", "school", "college", "university", "church", "court",
    "prison", "jail", "hospital", "sea", "town", "work", "class", "office",
    "hand", "foot", "car", "bus", "train", "plane", "horseback", "night",
    "noon", "midnight", "dawn", "dusk", "sunrise", "sunset", "day", "person",
    "page", "line", "chapter", "stage", "page", "heart", "mind", "sight",
}

# Nouns that are article-less inside fixed prepositional frames such as
# "in answer to", "on behalf of", "in charge of" — skipped for metric 6 when
# they sit directly under a preposition.
PREP_FRAME_NOUNS = {
    "answer", "response", "reply", "regard", "regards", "case", "order",
    "front", "means", "behalf", "charge", "search", "need", "spite", "favor",
    "favour", "light", "terms", "term", "view", "addition", "lieu", "place",
    "exchange", "return", "contrast", "comparison", "accordance", "connection",
    "relation", "reference", "respect", "default", "proportion", "keeping",
    "line", "control", "demand", "stock", "touch", "force", "effect", "turn",
    "person", "fact", "course", "general", "particular", "advance", "doubt",
    "danger", "trouble", "love", "fashion", "style", "practice", "principle",
    "theory", "name", "favour", "part", "vain", "earnest", "private", "public",
}

# Common uncountable / mass nouns that legitimately take no article (metric 6).
UNCOUNTABLE_NOUNS = {
    "water", "information", "music", "advice", "money", "furniture", "work",
    "research", "news", "knowledge", "evidence", "luggage", "equipment",
    "homework", "traffic", "weather", "progress", "luck", "fun", "help",
    "honesty", "patience", "wisdom", "courage", "freedom", "happiness",
    "health", "wealth", "food", "rice", "bread", "milk", "coffee", "tea",
    "sugar", "salt", "air", "oxygen", "electricity", "energy", "love", "hate",
    "anger", "fear", "joy", "peace", "war", "crime", "justice", "truth",
    "beauty", "nature", "society", "history", "math", "science", "art",
    "money", "stuff", "data", "software", "hardware", "feedback", "content",
    "nonsense", "blood", "fire", "smoke", "dust", "rain", "snow", "ice",
    "time", "space", "death", "life", "sleep", "respect", "trust", "hope",
}

# Verbs that commonly take an optional "that"-complement (metric 7).
THAT_TAKING_VERBS = {
    "think", "believe", "know", "say", "prove", "hope", "suppose", "feel",
    "guess", "reckon", "assume", "imagine", "realize", "realise", "understand",
    "admit", "claim", "consider", "decide", "doubt", "expect", "fear", "find",
    "forget", "hear", "mean", "notice", "remember", "see", "show", "state",
    "suggest", "suspect", "wish", "agree", "argue", "conclude", "declare",
    "explain", "insist", "mention", "promise", "remark", "reply", "report",
    "swear", "warn", "wonder", "assert", "contend", "maintain", "observe",
}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def _clean_sentence(text: str) -> str:
    """Collapse whitespace in a sentence for tidy display."""
    return re.sub(r"\s+", " ", text).strip()


def _highlight(sentence: str, target: str) -> str:
    """Wrap the first occurrence of `target` in »...« for readable examples."""
    idx = sentence.lower().find(target.lower())
    if idx == -1:
        return sentence
    return sentence[:idx] + "»" + sentence[idx:idx + len(target)] + "«" + sentence[idx + len(target):]


def normalize_apostrophes(text: str) -> str:
    return text.replace("’", "'").replace("‘", "'")


def clean_letter_text(text: str) -> str:
    """
    Optional cleaner ported from the original in_before_gerund.py: drops common
    salutations / closings so they don't skew the stats. Off by default.
    """
    out = []
    skip_prefixes = ("dear ", "sincerely", "very sincerely", "all best wishes",
                     "cordially", "my dear ", "yours ", "best regards",
                     "kind regards", "regards,", "warmly")
    for line in text.splitlines():
        s = line.strip()
        low = s.lower()
        if any(low.startswith(p) for p in skip_prefixes):
            continue
        if s:
            out.append(s)
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# Metric 1 — "rather" as a degree adverb
# --------------------------------------------------------------------------- #


def metric_rather(doc, text) -> MetricResult:
    hits = []
    spans = []
    for tok in doc:
        if tok.lower_ == "rather" and tok.dep_ == "advmod" and tok.head.pos_ in ("ADJ", "ADV"):
            hits.append((tok, tok.sent))
            spans.append([tok.idx, tok.idx + len(tok)])

    n_words = sum(1 for t in doc if not t.is_space and not t.is_punct)
    rate = (len(hits) / n_words * 1000) if n_words else 0
    examples = [_highlight(_clean_sentence(s.text), "rather") for _, s in hits[:8]]

    return MetricResult(
        key="rather",
        title="“Rather” as a degree adverb",
        headline=f"{len(hits)} degree use(s) of “rather”  ·  {rate:.2f} per 1,000 words",
        stats={"count": len(hits), "per_1000_words": round(rate, 3), "words": n_words},
        examples=examples,
        spans=spans,
        note="Counts only intensifier uses like “rather angry”; ignores “rather than” and “would rather”.",
    )


# --------------------------------------------------------------------------- #
# Metric 2 — "in" before a gerund
# --------------------------------------------------------------------------- #


def metric_in_before_gerund(doc, text) -> MetricResult:
    total_gerunds = 0
    hits = []
    spans = []
    for tok in doc:
        if tok.tag_ == "VBG":
            total_gerunds += 1
            prev = doc[tok.i - 1] if tok.i > 0 else None
            if prev is not None and prev.lower_ == "in":
                hits.append(tok.sent)
                spans.append([prev.idx, tok.idx + len(tok)])

    pct = (len(hits) / total_gerunds * 100) if total_gerunds else 0
    examples = [_highlight(_clean_sentence(s.text), "in ") for s in _dedupe_sents(hits)[:8]]

    return MetricResult(
        key="in_before_gerund",
        title="“In” before a gerund",
        headline=f"{len(hits)} of {total_gerunds} gerunds follow “in”  ·  {pct:.1f}%",
        stats={"in_gerund": len(hits), "total_gerunds": total_gerunds, "percentage": round(pct, 2)},
        examples=examples,
        spans=spans,
        note="e.g. “…fun in trying to catch me.”",
    )


# --------------------------------------------------------------------------- #
# Metric 3 — contraction rate
# --------------------------------------------------------------------------- #

_CONTRACTIONS = sorted({
    "'bout", "'cause", "'em", "'round", "'til", "'tis", "ain't", "aren't",
    "c'mon", "can't", "could've", "couldn't", "cuz", "didn't", "doesn't",
    "don't", "dunno", "everybody's", "everyone's", "everything's", "gimme",
    "gonna", "gotta", "hadn't", "hasn't", "haven't", "he'd", "he'll", "he's",
    "here's", "how'd", "how're", "how's", "i'd", "i'll", "i'm", "i've", "isn't",
    "it'd", "it'll", "it's", "kinda", "lemme", "let's", "mightn't", "needn't",
    "shan't", "she'd", "she'll", "she's", "should've", "shouldn't", "that'd",
    "that'll", "that're", "that's", "there'd", "there'll", "there're",
    "there's", "they'd", "they'll", "they're", "they've", "wanna", "wasn't",
    "we'd", "we'll", "we're", "we've", "weren't", "what'd", "what'll", "what's",
    "what've", "whatcha", "when'd", "when's", "where'd", "where's", "who'd",
    "who'll", "who're", "who's", "who've", "why'd", "why's", "won't",
    "would've", "wouldn't", "y'all",
}, key=len, reverse=True)

_NON_CONTRACTIONS = [
    "about", "am not", "are not", "around", "because", "can not", "cannot",
    "come on", "could have", "could not", "did not", "do not", "does not",
    "give me", "going to", "got to", "had not", "has not", "have not",
    "he had", "he has", "he is", "he will", "he would", "here is", "how are",
    "how did", "how is", "how would", "i am", "i had", "i have", "i will",
    "i would", "is not", "it had", "it is", "it will", "it would", "kind of",
    "let me", "let us", "might not", "need not", "shall not", "she had",
    "she has", "she is", "she will", "she would", "should have", "should not",
    "that are", "that had", "that is", "that will", "that would", "there are",
    "there had", "there is", "there will", "there would", "they are",
    "they had", "they have", "they will", "they would", "until", "want to",
    "was not", "we are", "we had", "we have", "we will", "we would",
    "were not", "what are", "what did", "what is", "what have", "when did",
    "when is", "where did", "where is", "who are", "who did", "who had",
    "who has", "who have", "who is", "who will", "who would", "why did",
    "why is", "will not", "would have", "would not", "you all",
]


def metric_contractions(doc, text) -> MetricResult:
    low = normalize_apostrophes(text.lower())
    contracted = Counter()
    spans = []
    for c in _CONTRACTIONS:
        matches = list(re.finditer(rf"(?<!\w){re.escape(c)}(?!\w)", low))
        if matches:
            contracted[c] = len(matches)
            spans.extend([m.start(), m.end()] for m in matches)
    expanded = Counter()
    for nc in _NON_CONTRACTIONS:
        n = len(re.findall(rf"(?<!\w){re.escape(nc)}(?!\w)", low))
        if n:
            expanded[nc] = n

    total_c = sum(contracted.values())
    total_e = sum(expanded.values())
    total = total_c + total_e
    pct = (total_c / total * 100) if total else 0
    top = ", ".join(f"{w} ({n})" for w, n in contracted.most_common(6))

    return MetricResult(
        key="contractions",
        title="Contraction rate",
        headline=f"{pct:.1f}% contracted  ·  {total_c} contracted vs {total_e} expanded form(s)",
        stats={
            "contracted": total_c,
            "expanded": total_e,
            "percentage": round(pct, 2),
            "top_contractions": dict(contracted.most_common(10)),
            "top_expanded": dict(expanded.most_common(10)),
        },
        examples=[f"Most common contractions: {top}"] if top else [],
        spans=spans,
        note="Rate = contracted ÷ (contracted + expandable forms). A writer who avoids contractions scores low. Highlights mark the contractions used.",
    )


# --------------------------------------------------------------------------- #
# Metric 4 — will vs shall
# --------------------------------------------------------------------------- #


def metric_will_shall(doc, text) -> MetricResult:
    will_m = list(re.finditer(r"\bwill\b", text, re.IGNORECASE))
    shall_m = list(re.finditer(r"\bshall\b", text, re.IGNORECASE))
    will, shall = len(will_m), len(shall_m)
    total = will + shall
    pct = (shall / total * 100) if total else 0
    spans = [[m.start(), m.end()] for m in (will_m + shall_m)]
    return MetricResult(
        key="will_shall",
        title="“Will” vs “shall”",
        headline=f"shall {shall} · will {will}  ·  {pct:.1f}% of modals are “shall”",
        stats={"will": will, "shall": shall, "shall_percentage": round(pct, 2)},
        examples=[],
        spans=spans,
        note="High “shall” share is a strong, old-fashioned/formal stylistic marker.",
    )


# --------------------------------------------------------------------------- #
# Metric 5 — possessive determiner + gerund
# --------------------------------------------------------------------------- #


# Dependency labels that signal an -ing word is behaving like a VERB (gerund)
# rather than a plain noun — used to disambiguate "your asking for X" (gerund)
# from "your morning" (plain noun).
_VERBAL_CHILD_DEPS = {
    "dobj", "dative", "prep", "acomp", "advmod", "prt", "npadvmod",
    "ccomp", "xcomp", "oprd", "agent", "nmod", "advcl", "neg",
}


def metric_possessive_gerund(doc, text) -> MetricResult:
    hits = []
    seen = set()
    for tok in doc:
        if tok.tag_ != "PRP$":
            continue
        head = tok.head
        # Case A: spaCy tagged the -ing word as a true gerund verb (VBG).
        # Case B: spaCy tagged it as a noun (NN) — the usual outcome after a
        #   possessive — so we accept it only if it still shows verbal behaviour
        #   (e.g. "your asking FOR more details": 'asking' governs a PP).
        is_gerund = head.tag_ == "VBG" or (
            head.lower_.endswith("ing")
            and head.pos_ in ("NOUN", "VERB")
            and any(c is not tok and c.dep_ in _VERBAL_CHILD_DEPS for c in head.children)
        )
        if is_gerund and head.i not in seen:
            seen.add(head.i)
            hits.append((tok, head, tok.sent))

    n_words = sum(1 for t in doc if not t.is_space and not t.is_punct)
    rate = (len(hits) / n_words * 1000) if n_words else 0
    examples = [_highlight(_clean_sentence(s.text), f"{p.text} {h.text}") for p, h, s in hits[:8]]
    spans = [[p.idx, h.idx + len(h)] for p, h, _ in hits]

    return MetricResult(
        key="possessive_gerund",
        title="Possessive determiner + gerund",
        headline=f"{len(hits)} possessive+gerund construction(s)  ·  {rate:.2f} per 1,000 words",
        stats={"count": len(hits), "per_1000_words": round(rate, 3)},
        examples=examples,
        spans=spans,
        note="e.g. “…your asking for more details.” A formal construction (possessive before a gerund).",
    )


# --------------------------------------------------------------------------- #
# Metric 6 — dropped / missing article (heuristic)
# --------------------------------------------------------------------------- #


def metric_dropped_article(doc, text) -> MetricResult:
    candidates = []
    for tok in doc:
        if tok.pos_ != "NOUN" or tok.tag_ != "NN":
            continue  # singular common nouns only
        if tok.dep_ == "compound":
            continue  # head noun carries the determiner
        lemma = tok.lemma_.lower()
        if lemma in UNCOUNTABLE_NOUNS or lemma in ARTICLELESS_IDIOM_NOUNS:
            continue
        # skip fixed prepositional frames: "in answer to", "on behalf of"…
        if (lemma in PREP_FRAME_NOUNS or tok.lower_ in PREP_FRAME_NOUNS) and tok.head.pos_ == "ADP":
            continue
        children = list(tok.children)
        if any(c.dep_ in ("det", "poss", "predet", "nummod") for c in children):
            continue  # already has an article / possessive / number
        # skip if any left child is a possessive-'s marker or another determiner
        if any(c.dep_ == "case" and c.lower_ == "'s" for c in children):
            continue
        # Focus on object / oblique / complement positions where a singular
        # count noun would normally need an article.
        if tok.dep_ not in ("dobj", "pobj", "obj", "obl", "attr", "dative", "nsubj", "nsubjpass"):
            continue
        # skip if immediately preceded by another noun (likely compound we missed)
        prev = doc[tok.i - 1] if tok.i > 0 else None
        if prev is not None and prev.pos_ in ("NOUN", "PROPN", "ADJ"):
            # adjective/compound modifier present but still no article -> still suspicious,
            # but skip PROPN/NOUN to avoid name+noun and compound noise
            if prev.pos_ in ("NOUN", "PROPN"):
                continue
        candidates.append(tok)

    examples = []
    for tok in candidates[:10]:
        examples.append(_highlight(_clean_sentence(tok.sent.text), tok.text))
    spans = [[tok.idx, tok.idx + len(tok)] for tok in candidates]

    n_words = sum(1 for t in doc if not t.is_space and not t.is_punct)
    rate = (len(candidates) / n_words * 1000) if n_words else 0

    return MetricResult(
        key="dropped_article",
        title="Dropped / missing article (heuristic)",
        headline=f"{len(candidates)} candidate(s) of an article-less singular noun  ·  {rate:.2f} per 1,000 words",
        stats={"candidates": len(candidates), "per_1000_words": round(rate, 3)},
        examples=examples,
        spans=spans,
        note=("HEURISTIC — flags singular count nouns in object/subject position with no "
              "the/a/an/possessive (e.g. “…back to developer”). Review each; mass nouns, "
              "generics and idioms are filtered but false positives remain."),
    )


# --------------------------------------------------------------------------- #
# Metric 7 — complementizer inclusion vs deletion
# --------------------------------------------------------------------------- #


def metric_complementizer(doc, text) -> MetricResult:
    rel_overt = 0      # relative clauses with which/that/who
    rel_zero = 0       # contact relatives (omitted relativizer)
    comp_overt = 0     # that-complement present
    comp_zero = 0      # that-complement omitted
    examples = []
    spans = []

    for tok in doc:
        # ---- relative clauses ----
        if tok.dep_ == "relcl":
            rel_words = [c for c in tok.children
                         if c.lower_ in ("that", "which", "who", "whom", "whose")
                         and c.dep_ in ("nsubj", "nsubjpass", "dobj", "pobj", "mark", "attr", "poss")]
            # also catch a relativizer that is the verb's own subject/object
            if rel_words:
                rel_overt += 1
                rw = rel_words[0]
                spans.append([rw.idx, rw.idx + len(rw)])
            else:
                # zero-relative only when the relative clause has its own overt subject
                # (object relatives: "facts [Ø] I know") — avoids reduced/participial clauses
                has_subj = any(c.dep_ in ("nsubj", "nsubjpass") for c in tok.children)
                if has_subj and tok.tag_ in ("VBP", "VBZ", "VBD", "VB", "MD"):
                    rel_zero += 1
                    spans.append([tok.idx, tok.idx + len(tok)])
                    if len(examples) < 8:
                        examples.append("· zero relative: " + _clean_sentence(tok.sent.text))

        # ---- that-complement clauses ----
        if tok.dep_ == "ccomp":
            has_that = any(c.dep_ == "mark" and c.lower_ == "that" for c in tok.children)
            head = tok.head
            if has_that:
                comp_overt += 1
                marks = [c for c in tok.children if c.dep_ == "mark" and c.lower_ == "that"]
                if marks:
                    spans.append([marks[0].idx, marks[0].idx + len(marks[0])])
            elif head.lemma_.lower() in THAT_TAKING_VERBS:
                # exclude wh / if complements
                has_wh = any(c.lower_ in ("if", "whether", "what", "why", "how",
                                          "when", "where", "who", "which")
                             for c in tok.children)
                if not has_wh:
                    comp_zero += 1
                    spans.append([tok.idx, tok.idx + len(tok)])
                    if len(examples) < 8:
                        examples.append("· zero “that”: " + _clean_sentence(tok.sent.text))

    rel_total = rel_overt + rel_zero
    comp_total = comp_overt + comp_zero
    rel_ret = (rel_overt / rel_total * 100) if rel_total else 0
    comp_ret = (comp_overt / comp_total * 100) if comp_total else 0

    return MetricResult(
        key="complementizer",
        title="Complementizer inclusion vs deletion",
        headline=(f"relative which/that kept {rel_ret:.0f}% ({rel_overt}/{rel_total}) · "
                  f"“that”-clause kept {comp_ret:.0f}% ({comp_overt}/{comp_total})"),
        stats={
            "relative_overt": rel_overt, "relative_zero": rel_zero,
            "relative_retention_pct": round(rel_ret, 1),
            "that_overt": comp_overt, "that_zero": comp_zero,
            "that_retention_pct": round(comp_ret, 1),
        },
        examples=examples,
        spans=spans,
        note=("Retention = how often the writer KEEPS which/that. Low retention means a "
              "tendency to drop it (“facts Ø I know”, “prove Ø I am”). Parser-based, approximate."),
    )


# --------------------------------------------------------------------------- #
# Metric 8 — "is this" + cataphoric prompt
# --------------------------------------------------------------------------- #


def metric_is_this(doc, text) -> MetricResult:
    norm = normalize_apostrophes(text)
    # "is this" immediately followed by , : ; — or . then a clause
    pattern = re.compile(r"\bis this\b\s*([:,;—–-]|\.\s)\s*([^.?!]{2,}[.?!])", re.IGNORECASE)
    hits = []
    spans = []
    for m in pattern.finditer(norm):
        frag = _clean_sentence(norm[max(0, m.start() - 30):m.end()])
        hits.append("…" + frag)
        spans.append([m.start(), m.end()])

    total_is_this = len(re.findall(r"\bis this\b", norm, re.IGNORECASE))

    return MetricResult(
        key="is_this",
        title="“Is this” + cataphoric prompt",
        headline=f"{len(hits)} cataphoric “is this …” of {total_is_this} total “is this”",
        stats={"cataphoric": len(hits), "total_is_this": total_is_this},
        examples=hits[:8],
        spans=spans,
        note="Catches “…the one thing I ask of you is this, please help me.” (a colon/comma then a directive).",
    )


# --------------------------------------------------------------------------- #
# Metric 9 — top-3 degree adverbs share
# --------------------------------------------------------------------------- #


def metric_top_degree_adverbs(doc, text) -> MetricResult:
    counts = Counter()
    spans = []
    for tok in doc:
        if tok.dep_ == "advmod" and tok.head.pos_ in ("ADJ", "ADV") and tok.lower_ in DEGREE_ADVERBS:
            counts[tok.lower_] += 1
            spans.append([tok.idx, tok.idx + len(tok)])

    total = sum(counts.values())
    top3 = counts.most_common(3)
    top3_sum = sum(n for _, n in top3)
    share = (top3_sum / total * 100) if total else 0
    top3_str = ", ".join(f"{w} ({n})" for w, n in top3) if top3 else "—"

    return MetricResult(
        key="top_degree_adverbs",
        title="Top-3 degree adverbs",
        headline=f"top 3 = {top3_str}  ·  {share:.0f}% of all degree-adverb use",
        stats={
            "total_degree_adverbs": total,
            "top3": dict(top3),
            "top3_share_pct": round(share, 1),
            "all": dict(counts.most_common()),
        },
        examples=[],
        spans=spans,
        note="Degree adverbs = intensifiers modifying an adjective/adverb (very, quite, rather…).",
    )


# --------------------------------------------------------------------------- #
# Metric 10 — phrase / word rarity (optional; needs `wordfreq`)
# --------------------------------------------------------------------------- #


def _wordfreq_available() -> bool:
    try:
        import wordfreq  # noqa: F401
        return True
    except Exception:
        return False


def metric_rarity(doc, text, phrase: Optional[str] = None) -> MetricResult:
    """
    COCA-style rarity. With the `wordfreq` package we score how rare words/phrases
    are in contemporary English (lower Zipf = rarer). If a `phrase` is supplied we
    score that; otherwise we surface the rarest content words in the document.
    """
    if not _wordfreq_available():
        return MetricResult(
            key="rarity",
            title="Phrase / word rarity (COCA-style)",
            headline="Install the `wordfreq` package to enable rarity scoring.",
            stats={},
            examples=[],
            note="pip install wordfreq — gives Zipf frequencies aggregated over large English corpora.",
        )

    from wordfreq import zipf_frequency, tokenize

    def phrase_zipf(p: str):
        toks = [t for t in tokenize(p, "en") if t.isalpha()]
        if not toks:
            return None, []
        per = [(t, zipf_frequency(t, "en")) for t in toks]
        # phrase rarity ~ rarest word in it (the limiting factor)
        rarest = min(per, key=lambda x: x[1])
        return rarest[1], per

    examples = []
    stats = {}

    if phrase:
        z, per = phrase_zipf(phrase)
        band = _zipf_band(z) if z is not None else "—"
        stats = {"phrase": phrase, "phrase_zipf": z, "band": band,
                 "per_word_zipf": per}
        examples = [f"“{phrase}”  →  Zipf {z:.2f} ({band})" if z is not None else "no scorable words"]
        for w, zz in sorted(per, key=lambda x: x[1]):
            examples.append(f"    {w}: Zipf {zz:.2f} ({_zipf_band(zz)})")
        headline = f"“{_truncate(phrase, 40)}” → Zipf {z:.2f} ({band})" if z is not None else "no scorable words"
    else:
        # rarest content words actually used in the document
        seen = {}
        for tok in doc:
            if tok.is_alpha and not tok.is_stop and len(tok) > 2:
                w = tok.lower_
                if w not in seen:
                    seen[w] = zipf_frequency(w, "en")
        rare = sorted(seen.items(), key=lambda x: x[1])[:15]
        stats = {"rarest_words": rare}
        examples = [f"{w}: Zipf {z:.2f} ({_zipf_band(z)})" for w, z in rare]
        headline = f"{len(seen)} distinct content words scored; rarest shown below"

    return MetricResult(
        key="rarity",
        title="Phrase / word rarity (COCA-style)",
        headline=headline,
        stats=stats,
        examples=examples,
        note=("Zipf scale: ~7 = extremely common (‘the’), ~4 = ordinary, ≤3 = rare, ≤2 = very rare. "
              "Approximates COCA frequency using the aggregated `wordfreq` corpora."),
    )


def _zipf_band(z) -> str:
    if z is None:
        return "unknown"
    if z >= 5.5:
        return "very common"
    if z >= 4.0:
        return "common"
    if z >= 3.0:
        return "uncommon"
    if z >= 2.0:
        return "rare"
    return "very rare"


def _truncate(s, n):
    return s if len(s) <= n else s[: n - 1] + "…"


# --------------------------------------------------------------------------- #
# Small utilities
# --------------------------------------------------------------------------- #


def _dedupe_sents(sents):
    seen = set()
    out = []
    for s in sents:
        key = s.start
        if key not in seen:
            seen.add(key)
            out.append(s)
    return out


# --------------------------------------------------------------------------- #
# Top-level driver
# --------------------------------------------------------------------------- #

ALL_METRICS = [
    metric_rather,
    metric_in_before_gerund,
    metric_contractions,
    metric_will_shall,
    metric_possessive_gerund,
    metric_dropped_article,
    metric_complementizer,
    metric_is_this,
    metric_top_degree_adverbs,
]


def analyze_text(text: str, clean: bool = False, rarity_phrase: Optional[str] = None) -> dict:
    """Run every metric over `text` and return a structured report dict."""
    if clean:
        text = clean_letter_text(text)

    nlp = get_nlp()
    doc = nlp(text)

    n_words = sum(1 for t in doc if not t.is_space and not t.is_punct)
    n_sents = sum(1 for _ in doc.sents)

    results = [fn(doc, text) for fn in ALL_METRICS]
    # metric 10 takes an optional phrase arg, so call it separately
    results.append(metric_rarity(doc, text, phrase=rarity_phrase))

    return {
        "meta": {
            "words": n_words,
            "sentences": n_sents,
            "characters": len(text),
        },
        "text": text,   # the exact text the spans index into (post-clean if enabled)
        "metrics": [r.as_dict() for r in results],
    }


def analyze_file(path: str, clean: bool = False, rarity_phrase: Optional[str] = None) -> dict:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    report = analyze_text(text, clean=clean, rarity_phrase=rarity_phrase)
    report["meta"]["source"] = path
    return report


def format_report(report: dict) -> str:
    """Render a report as plain text (used for CLI + 'copy results')."""
    m = report["meta"]
    lines = [
        "=" * 64,
        "LangCheck — stylometric report",
        "=" * 64,
        f"words: {m['words']:,}   sentences: {m['sentences']:,}   chars: {m['characters']:,}",
    ]
    if m.get("source"):
        lines.append(f"source: {m['source']}")
    lines.append("")
    for r in report["metrics"]:
        lines.append(f"▸ {r['title']}")
        lines.append(f"   {r['headline']}")
        for ex in r["examples"]:
            lines.append(f"     · {ex}")
        if r["note"]:
            lines.append(f"   ({r['note']})")
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("usage: python analyzer.py <file.txt> [--clean] [--phrase \"some phrase\"]")
        raise SystemExit(1)
    path = sys.argv[1]
    clean = "--clean" in sys.argv
    phrase = None
    if "--phrase" in sys.argv:
        phrase = sys.argv[sys.argv.index("--phrase") + 1]
    print(format_report(analyze_file(path, clean=clean, rarity_phrase=phrase)))
