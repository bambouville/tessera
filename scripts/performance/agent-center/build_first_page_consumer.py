#!/usr/bin/env python3
"""Compile the real Apple decoder/shared reducer into a host-only consumer."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]


def build(output):
    # Reuse the integration gate's explicit shared-source dependency closure.
    build_script = (ROOT / "scripts/integration/build-agent-integration-dumper.sh").read_text()
    sources = re.findall(r'"\$REPO_ROOT/(Packages/[^"\n]+\.swift)"', build_script)
    if not sources:
        raise RuntimeError("integration_source_list_missing")
    apple = (ROOT / "Tessera/AgentCenterV2/Platform/AppleAgentStreamingDataChannel.swift").read_text()
    assert apple.count("import TesseraCore\n") == 1
    # Compile those exact declarations together instead of importing the app.
    apple = apple.replace("import TesseraCore\n", "")
    with tempfile.TemporaryDirectory(prefix="tessera-first-page-build-") as folder:
        scratch = Path(folder)
        source = scratch / "AppleAgentStreamingDataChannel.swift"
        source.write_text(apple)
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(scratch / "modules"),
                        *[str(ROOT / name) for name in sources],
                        str(ROOT / "Packages/TesseraCore/Sources/TesseraAgentCore/Projection/AgentProjectionDiagnostics.swift"),
                        str(ROOT / "scripts/integration/AgentMarkdownDumperStub.swift"),
                        str(source), str(Path(__file__).with_name("FirstPageConsumer.swift")),
                        "-o", str(output)], check=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: build_first_page_consumer.py OUTPUT")
    build(Path(sys.argv[1]).resolve())
