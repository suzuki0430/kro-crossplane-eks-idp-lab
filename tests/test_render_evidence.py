"""Check English screenshot captions and preserve escaped original evidence."""

import runpy
from pathlib import Path

RENDER = runpy.run_path(
    str(Path(__file__).resolve().parents[1] / "scripts" / "render-evidence.py")
)["render"]


def test_english_captions_preserve_evidence(tmp_path: Path) -> None:
    """English captions must retain the recorded timestamp and exact CLI facts."""
    source = tmp_path / "ready.txt"
    evidence = "EKS IDP LAB | ready | 2026-10-02T12:38:00Z\nReady=True\n"
    source.write_text(evidence, encoding="utf-8")
    output = RENDER(source).read_text(encoding="utf-8")
    assert "lang='en'" in output
    assert "Live AWS validation" in output
    assert "it is not the AWS console" in output
    assert evidence in output
    assert source.read_text(encoding="utf-8") == evidence


def test_evidence_is_text_not_executable_html(tmp_path: Path) -> None:
    """CLI error strings and filenames must not inject HTML into screenshots."""
    source = tmp_path / "<error>.txt"
    source.write_text("<script>alert('x')</script> & failure", encoding="utf-8")
    output = RENDER(source).read_text(encoding="utf-8")
    assert "<script>" not in output
    assert "&lt;script&gt;" in output
    assert "&amp; failure" in output
    assert "&lt;error&gt;.txt" in output
