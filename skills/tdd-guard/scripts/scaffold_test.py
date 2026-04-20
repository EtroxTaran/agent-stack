#!/usr/bin/env python3
"""scaffold_test.py - Generate a failing-test stub for a source file.

Given the path to a source file the user wants to edit, emit a
language-appropriate test-file stub to stdout (or, with --write,
materialize it next to the source using the conventional path).

Supported languages:
    - TypeScript / TSX (vitest)
    - JavaScript / JSX (vitest)
    - Python (pytest)
    - Go (testing)

Exit codes:
    0  stub emitted
    1  unsupported language / cannot infer
    2  argument error

Deutscher Kommentar: rein stdlib, damit das Skill-Script aus jeder CLI
ohne pip-install laeuft.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def infer_language(path: Path) -> str | None:
    suffix = path.suffix.lower()
    if suffix in {".ts", ".tsx"}:
        return "ts"
    if suffix in {".js", ".jsx"}:
        return "js"
    if suffix == ".py":
        return "py"
    if suffix == ".go":
        return "go"
    return None


def ts_stub(src: Path, module_name: str) -> str:
    rel = f"./{src.name[:-len(src.suffix)]}"
    return f"""import {{ describe, it, expect }} from 'vitest';
// Deutscher Kommentar: TDD Red-State. Dieser Test MUSS zuerst rot laufen,
// bevor eine Implementierung in {src.name} entsteht.
import {{ /* export-name-here */ }} from '{rel}';

describe('{module_name}', () => {{
  it('should <describe the first behaviour in intent form>', () => {{
    // Arrange
    const input = /* minimal input */ null;

    // Act
    const result = /* call-the-function */ undefined;

    // Assert
    expect(result).toBe(/* expected */ null);
  }});
}});
"""


def py_stub(src: Path, module_name: str) -> str:
    return f"""\"\"\"Tests for {src.stem}. TDD Red-State.

Deutscher Kommentar: Test muss zuerst rot laufen, bevor {src.name}
implementiert wird. Pattern: Arrange-Act-Assert (AAA).
\"\"\"
# from .{src.stem} import <symbol-to-test>


def test_{module_name.replace('-', '_')}_should_describe_first_behaviour() -> None:
    # Arrange
    # input = ...

    # Act
    # result = ...

    # Assert
    assert False, "TDD Red: implement test, then implement {src.name}"
"""


def go_stub(src: Path, module_name: str) -> str:
    pkg = src.parent.name or "main"
    return f"""package {pkg}

import (
    "testing"
)

// Deutscher Kommentar: TDD Red-State. Erst rot, dann gruen.
func Test{module_name.title().replace('-', '').replace('_', '')}(t *testing.T) {{
    // Arrange
    // input := ...

    // Act
    // got := ...

    // Assert
    t.Fatalf("TDD Red: implement test, then implement {src.name}")
}}
"""


def target_test_path(src: Path, lang: str) -> Path:
    if lang in ("ts", "js"):
        return src.with_suffix(f".test{src.suffix}")
    if lang == "py":
        return src.parent / f"test_{src.stem}.py"
    if lang == "go":
        return src.parent / f"{src.stem}_test.go"
    raise ValueError(f"unsupported lang: {lang}")


def render(src: Path, lang: str) -> str:
    module_name = src.stem
    if lang in ("ts", "js"):
        return ts_stub(src, module_name)
    if lang == "py":
        return py_stub(src, module_name)
    if lang == "go":
        return go_stub(src, module_name)
    raise ValueError(f"unsupported lang: {lang}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", help="Path to source file the user wants to edit")
    ap.add_argument("--write", action="store_true",
                    help="Write the stub next to source (refuses to overwrite)")
    ap.add_argument("--lang", help="Force language (ts|js|py|go); auto-inferred otherwise")
    args = ap.parse_args()

    src = Path(args.source)
    lang = args.lang or infer_language(src)
    if not lang:
        print(f"scaffold_test: cannot infer language from '{src}'; pass --lang",
              file=sys.stderr)
        return 1

    try:
        stub = render(src, lang)
    except ValueError as e:
        print(f"scaffold_test: {e}", file=sys.stderr)
        return 1

    if args.write:
        target = target_test_path(src, lang)
        if target.exists():
            print(f"scaffold_test: refusing to overwrite existing {target}",
                  file=sys.stderr)
            return 1
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(stub, encoding="utf-8")
        print(str(target))
    else:
        sys.stdout.write(stub)
    return 0


if __name__ == "__main__":
    sys.exit(main())
