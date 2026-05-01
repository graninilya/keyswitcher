#!/usr/bin/env python3
"""
Сборка ассетов для приложения. Версия 3 — без Punto.

Все данные генерируются АЛГОРИТМИЧЕСКИ из открытых hunspell-словарей:
  - LibreOffice ru_RU.dic (LGPL)
  - LibreOffice en_US.dic (MPL/LGPL/BSD)

Принцип:
  Для каждого языка X (EN/RU) собираем все «естественные» 3..6-граммы из словаря.
  Для другого языка Y, делаем layout-swap всех слов и собираем граммы.
  «Плохие» граммы языка X = граммы свапа Y, которых нет в естественных X.
"""
import json
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).parent.parent
RAW = ROOT / "dictionaries" / "raw"
OUT = ROOT / "dictionaries" / "processed"
OUT.mkdir(parents=True, exist_ok=True)

NGRAM_LENGTHS = (2, 3, 4, 5, 6)


# ──────────────────────────────────────────────────────────────────────────────
# Мапа раскладок ЙЦУКЕН ↔ QWERTY
# ──────────────────────────────────────────────────────────────────────────────
EN_LAYOUT = (
    "`1234567890-="
    "qwertyuiop[]\\"
    "asdfghjkl;'"
    "zxcvbnm,./"
)
RU_LAYOUT = (
    "ё1234567890-="
    "йцукенгшщзхъ\\"
    "фывапролджэ"
    "ячсмитьбю."
)
assert len(EN_LAYOUT) == len(RU_LAYOUT)


def build_layout_map():
    en2ru, ru2en = {}, {}
    for e, r in zip(EN_LAYOUT, RU_LAYOUT):
        en2ru[e] = r
        ru2en[r] = e
        # Заглавный mapping — только для букв (у пунктуации .upper()==self).
        if e.isalpha() and e != e.upper():
            en2ru[e.upper()] = r.upper()
        if r.isalpha() and r != r.upper():
            ru2en[r.upper()] = e.upper()

    # Альтернативная позиция для ё: на некоторых раскладках ё на `\` (Russian — PC),
    # а не на backtick. Мапим `\` тоже на ё. ru_to_en для ё уже стоит на ` (стандарт).
    en2ru["\\"] = "ё"
    en2ru["|"] = "Ё"
    return {"en_to_ru": en2ru, "ru_to_en": ru2en}


def swap_layout(s: str, lookup: dict) -> str:
    return "".join(lookup.get(c, c) for c in s)


# ──────────────────────────────────────────────────────────────────────────────
# Парсинг hunspell .dic
# ──────────────────────────────────────────────────────────────────────────────
def parse_hunspell(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    seen, out = set(), []
    for line in lines[1:]:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        word = line.split("/")[0].strip().lower()
        if word and not any(ch.isdigit() for ch in word) and word not in seen:
            seen.add(word)
            out.append(word)
    return out


# ──────────────────────────────────────────────────────────────────────────────
# Извлечение n-грамм
# ──────────────────────────────────────────────────────────────────────────────
def extract_ngrams(words: list[str], lengths=NGRAM_LENGTHS,
                   min_freq: int = 1, alphabet_check=None) -> set[str]:
    """
    Возвращает множество n-грамм из слов, встречающихся min_freq+ раз.
    alphabet_check — функция проверки что n-грамма из «правильного» алфавита.
    """
    counts = defaultdict(int)
    for w in words:
        for L in lengths:
            if len(w) < L:
                continue
            for i in range(len(w) - L + 1):
                ng = w[i:i+L]
                if alphabet_check is None or alphabet_check(ng):
                    counts[ng] += 1
    return {ng for ng, c in counts.items() if c >= min_freq}


def is_pure_latin(s: str) -> bool:
    return bool(s) and all("a" <= c <= "z" for c in s)


def is_pure_cyrillic(s: str) -> bool:
    return bool(s) and all(("а" <= c <= "я") or c == "ё" for c in s)


# ──────────────────────────────────────────────────────────────────────────────
# Генерация плохих триггеров
# ──────────────────────────────────────────────────────────────────────────────
def generate_triggers(words_en: list[str], words_ru: list[str], layout_map: dict) -> dict:
    """
    bad_latin = свап русских слов даёт латиницу — её n-граммы. Минус n-граммы
    реальных английских слов. Остаётся «латиница, которая на самом деле русский».

    bad_cyrillic = свап английских слов в кириллицу. Минус кириллица из реальных
    русских слов. Остаётся «кириллица, которая на самом деле английский».
    """
    ru2en = layout_map["ru_to_en"]
    en2ru = layout_map["en_to_ru"]

    print("  Сбор естественных n-грамм EN…")
    natural_latin = extract_ngrams(words_en, alphabet_check=is_pure_latin, min_freq=2)
    print(f"    {len(natural_latin)}")

    print("  Сбор естественных n-грамм RU…")
    natural_cyr = extract_ngrams(words_ru, alphabet_check=is_pure_cyrillic, min_freq=2)
    print(f"    {len(natural_cyr)}")

    print("  Свап RU → латиница, сбор n-грамм…")
    ru_swapped = [swap_layout(w, ru2en) for w in words_ru]
    ru_as_latin_ngrams = extract_ngrams(ru_swapped, alphabet_check=is_pure_latin, min_freq=2)
    print(f"    {len(ru_as_latin_ngrams)}")

    print("  Свап EN → кириллица, сбор n-грамм…")
    en_swapped = [swap_layout(w, en2ru) for w in words_en]
    en_as_cyr_ngrams = extract_ngrams(en_swapped, alphabet_check=is_pure_cyrillic, min_freq=2)
    print(f"    {len(en_as_cyr_ngrams)}")

    bad_latin = ru_as_latin_ngrams - natural_latin
    bad_cyrillic = en_as_cyr_ngrams - natural_cyr

    return {
        "latin": sorted(bad_latin),
        "cyrillic": sorted(bad_cyrillic),
    }


# ──────────────────────────────────────────────────────────────────────────────
# main
# ──────────────────────────────────────────────────────────────────────────────
def main():
    print("1. Layout map…")
    layout = build_layout_map()
    (OUT / "layout_map.json").write_text(
        json.dumps(layout, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print("2. Парсинг hunspell…")
    words_ru = parse_hunspell(RAW / "hunspell" / "ru_RU.dic")
    words_en = parse_hunspell(RAW / "hunspell" / "en_US.dic")
    (OUT / "words_ru.json").write_text(json.dumps(words_ru, ensure_ascii=False), encoding="utf-8")
    (OUT / "words_en.json").write_text(json.dumps(words_en, ensure_ascii=False), encoding="utf-8")
    print(f"   ru: {len(words_ru)}, en: {len(words_en)}")

    print("3. Генерация плохих триггеров…")
    triggers = generate_triggers(words_en, words_ru, layout)
    print(f"   bad_latin: {len(triggers['latin'])}")
    print(f"   bad_cyrillic: {len(triggers['cyrillic'])}")

    (OUT / "bad_ngrams.json").write_text(
        json.dumps(triggers, ensure_ascii=False), encoding="utf-8"
    )

    print("\nГотово:")
    for f in sorted(OUT.glob("*.json")):
        print(f"  {f.name}: {f.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
