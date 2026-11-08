#!/usr/bin/env python3
"""Makes a new owner code and the constants that go into lib/billing/owner_access.dart.

Usage: python3 tool/owner_code/new_owner_code.py <output file OUTSIDE the repository>

- The code (30 Crockford base32 characters from a CSPRNG, shown as XXXXXX-XXXXXX-...) is
  written ONLY to the output file (mode 600). It is never printed.
- Printed: the Dart constants (_ownerSeed, _ownerMasked, _ownerIterations) holding a salted
  PBKDF2-HMAC-SHA256 hash of the code, lightly XOR-masked. Paste them over the old ones.
"""
import hashlib
import os
import secrets
import subprocess
import sys

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"  # Crockford base32 (no I, L, O, U)
ITERATIONS = 210_000


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = os.path.abspath(sys.argv[1])
    try:
        root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        root = ""
    if root and (out + os.sep).startswith(os.path.abspath(root) + os.sep):
        sys.exit("Refusing to write the owner code inside the repository.")

    code = "".join(secrets.choice(ALPHABET) for _ in range(30))
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", code.encode(), salt, ITERATIONS, 32)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("-".join(code[i:i + 6] for i in range(0, 30, 6)) + "\n")

    seed = secrets.token_bytes(12)
    data = salt + digest
    mask, h = b"", seed
    while len(mask) < len(data):
        h = hashlib.sha256(h).digest()
        mask += h
    masked = [data[i] ^ mask[i] ^ ((i * 29 + 11) & 0xFF) for i in range(len(data))]
    rows = ",\n  ".join(", ".join(str(x) for x in masked[i:i + 16]) for i in range(0, len(masked), 16))
    print(f"const List<int> _ownerSeed = [{', '.join(str(x) for x in seed)}];")
    print(f"const List<int> _ownerMasked = [\n  {rows},\n];")
    print(f"const int _ownerIterations = {ITERATIONS};")
    print(f"# owner code written to {out} (not printed)", file=sys.stderr)


if __name__ == "__main__":
    main()
