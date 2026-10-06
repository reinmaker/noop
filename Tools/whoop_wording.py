#!/usr/bin/env python3
"""WHOOP-style fork: rename NOOP's score names in the English string catalogs.

Charge -> Recovery, Effort -> Strain, Rest -> Sleep, and the app name NOOP -> Yoop. Only the English ("en") localization is
written; catalog keys and other languages are untouched, so the Swift code needs no changes.
Battery "Charge" (charge the strap) and gym "Rest" (rest period / resting HR) are left alone.
Idempotent: re-running after an upstream merge re-applies the rename.
"""
import json, re, sys

CATALOGS = [
    "Strand/Resources/Localizable.xcstrings",
    "NOOPWatch/Localizable.xcstrings",
    "NOOPWatchComplications/Localizable.xcstrings",
]
SKIP_CHARGE = re.compile(r"\bCharge (before|it|your)\b")
SKIP_REST = re.compile(r"\bRest (\(seconds\)|period\b|HR\b|up\b)")
# Entries whose English text must keep NOOP's word: the low-readiness tip "Rest" (take it easy) has its
# own key precisely so it is not renamed with the Rest (sleep) score.
SKIP_KEYS = {"readiness.rest"}


def rename(text: str) -> str:
    if not (SKIP_CHARGE.search(text) or SKIP_REST.search(text)):
        text = re.sub(r"\bCharge\b", "Recovery", text)
        text = re.sub(r"\bRest\b", "Sleep", text)
    text = re.sub(r"\bEffort\b", "Strain", text)
    # The fork's app name.
    text = re.sub(r"\bNOOP\b", "Yoop", text)
    # Tidy phrases that now say the same word twice.
    text = text.replace("Recovery / Recovery", "Recovery")
    text = text.replace("Recovery, NOOP's Recovery score,", "Recovery")
    text = text.replace("Recovery (recovery)", "Recovery")
    text = re.sub(r"\bSleep( &| /|,| and| or) Sleep\b", "Sleep", text)
    return text


def transform(node):
    """Rename every stringUnit value inside an en localization (handles plural variations)."""
    changed = False
    if isinstance(node, dict):
        unit = node.get("stringUnit")
        if isinstance(unit, dict) and isinstance(unit.get("value"), str):
            new = rename(unit["value"])
            if new != unit["value"]:
                unit["value"], unit["state"], changed = new, "translated", True
        for k, v in node.items():
            if k != "stringUnit":
                changed |= transform(v)
    elif isinstance(node, list):
        for v in node:
            changed |= transform(v)
    return changed


def find_value_span(text: str, start: int):
    """Span of the JSON string literal after the next `"value"` key at/after `start`."""
    m = re.compile(r'"value"\s*:\s*"').search(text, start)
    i = m.end()
    while text[i] != '"':
        i += 2 if text[i] == "\\" else 1
    return m.end() - 1, i + 1


def patch(raw: str):
    """Surgical text edits (the catalogs are partly hand-formatted, so never re-serialise them)."""
    data = json.loads(raw)
    expected = json.loads(raw)
    edits = []  # (start, end, replacement)
    count = 0
    for key, entry in data["strings"].items():
        if key in SKIP_KEYS:
            continue
        exp = expected["strings"][key]
        locs = exp.get("localizations", {})
        enc = json.dumps(key, ensure_ascii=False)
        km = re.compile(re.escape(enc) + r"\s*:\s*\{").search(raw)
        if "en" in locs:
            if not transform(locs["en"]):
                continue
            unit = locs["en"].get("stringUnit")
            if not unit:
                sys.exit(f"plural/variation en entry not supported: {key!r}")
            em = re.compile(r'"en"\s*:\s*\{').search(raw, km.end())
            a, b = find_value_span(raw, em.end())
            edits.append((a, b, json.dumps(unit["value"], ensure_ascii=False)))
            # state may have been e.g. "new"; leave the literal state text alone unless needed
            count += 1
        else:
            new = rename(key)
            if new == key:
                continue
            unit = {"state": "translated", "value": new}
            ins = '"en": {"stringUnit": ' + json.dumps(unit, ensure_ascii=False) + '}'
            if "localizations" not in data["strings"][key]:
                # An entry with no localizations block at all: add one right inside the entry.
                empty = not data["strings"][key]
                edits.append((km.end(), km.end(), '"localizations": {' + ins + '}' + ("" if empty else ", ")))
                exp.setdefault("localizations", {})["en"] = {"stringUnit": unit}
                count += 1
                continue
            lm = re.compile(r'"localizations"\s*:\s*\{').search(raw, km.end())
            if lm and not re.compile(r'^\s*\}').match(raw, lm.end()):
                edits.append((lm.end(), lm.end(), ins + ", "))
            elif lm:
                edits.append((lm.end(), lm.end(), ins))
            else:
                sys.exit(f"no localizations block: {key!r}")
            exp.setdefault("localizations", {})["en"] = {"stringUnit": unit}
            count += 1
    for a, b, rep in sorted(edits, reverse=True):
        raw = raw[:a] + rep + raw[b:]
    got = json.loads(raw)
    # States aren't rewritten textually; compare values only.
    def strip(o):
        if isinstance(o, dict):
            return {k: strip(v) for k, v in o.items() if k != "state"}
        if isinstance(o, list):
            return [strip(v) for v in o]
        return o
    if strip(got) != strip(expected):
        sys.exit("verification failed: patched catalog != intended data")
    return raw, count


def main() -> int:
    total = 0
    for path in CATALOGS:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        raw, n = patch(raw)
        with open(path, "w", encoding="utf-8") as f:
            f.write(raw)
        total += n
    print(f"renamed {total} English strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
