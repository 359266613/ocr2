"""Optional libclang syntax check; not a substitute for a Theos build."""

import argparse
from pathlib import Path

from clang.cindex import Diagnostic, Index


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--headers", type=Path, required=True,
                        help="Compiler resource headers and Theos dependency headers")
    parser.add_argument("--target", default="arm64-apple-ios15.0")
    parser.add_argument("--without-neon", action="store_true",
                        help="Partial syntax check if generated compiler NEON headers are unavailable")
    parser.add_argument("files", nargs="*")
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    files = options.files or ["Shared/AxsScreenOcrVision.m", "Tests/AxsScreenOcrVisionTests.m"]
    arguments = ["-target", options.target, "-isysroot", str(options.sdk),
                 "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                 "-I" + str(root / "Shared"), "-I" + str(root / "Sources"),
                 "-I" + str(root / "AxsScreenOcrPrefs"),
                 "-isystem", str(options.headers), '-DTHEOS_PACKAGE_INSTALL_PREFIX=""']
    if options.without_neon:
        arguments.append("-U__ARM_NEON__")
    index = Index.create()
    failed = False
    for file in files:
        unit = index.parse(str(root / file), args=arguments)
        errors = [entry for entry in unit.diagnostics if entry.severity >= Diagnostic.Error]
        print(f"{file}: {'FAIL' if errors else 'syntax OK'}")
        for entry in unit.diagnostics:
            print(entry)
        failed |= bool(errors)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
