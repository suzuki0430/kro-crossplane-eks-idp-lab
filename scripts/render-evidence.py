#!/usr/bin/env python3
"""Render captured CLI text as local HTML for article screenshots.

Example:
    uv run --no-project python scripts/render-evidence.py .local/evidence

Only text recorded by capture-evidence.sh is rendered. This does not execute
commands, verify assertions, or simulate an AWS console. Review before sharing.
"""

import argparse
import html
from pathlib import Path


def render(source: Path) -> Path:
    """Escape a UTF-8 evidence file and write its sibling HTML screenshot view.

    Args:
        source: Text containing observations from an actual validation run.

    Returns:
        Path to the HTML file, with source content and capture time preserved.

    Example:
        render(Path(".local/evidence/ready.txt"))
    """
    text = source.read_text(encoding="utf-8")
    title = html.escape(source.stem)
    target = source.with_suffix(".html")
    target.write_text(
        "<!doctype html><html lang='ja'><meta charset='utf-8'>"
        f"<title>EKS IDP Lab — {title}</title>"
        "<style>body{margin:0;background:#edf2f7;color:#182435;"
        "font-family:system-ui,sans-serif}main{margin:32px auto;padding:32px;"
        "max-width:1120px;background:white;border-top:6px solid #247a86;"
        "border-radius:10px}h1{margin:8px 0 12px;font-size:28px}"
        ".label{color:#247a86;font-weight:700;font-size:14px;letter-spacing:2px}"
        "p,footer{color:#52657a;font-size:14px;line-height:1.6}"
        "pre{background:#101e30;color:#e2edf8;padding:24px;border-radius:8px;"
        "font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;"
        "white-space:pre-wrap;overflow-wrap:anywhere;tab-size:8}"
        "footer{margin-top:20px}</style><main>"
        "<div class='label'>KRO + CROSSPLANE + EKS</div>"
        f"<h1>実環境の検証記録 · {title}</h1>"
        "<p>AWS上で実行したCLI出力の保存記録です。"
        "アカウントIDは ACCOUNT_ID に置換しています。</p>"
        f"<pre>{html.escape(text)}</pre>"
        f"<footer>Source: {html.escape(source.name)} · "
        "suzuki0430/kro-crossplane-eks-idp-lab<br>"
        "この画面は保存済みのCLI出力を表示したものです。</footer></main></html>",
        encoding="utf-8",
    )
    return target


def main() -> None:
    """Render all .txt snapshots in the supplied directory; print output paths.

    Example:
        uv run --no-project python scripts/render-evidence.py .local/evidence
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    for source in sorted(args.directory.glob("*.txt")):
        print(render(source))


if __name__ == "__main__":
    main()
