#!/bin/bash
# validate-autoinstall.sh
#
# Validates autoinstall YAML variants for correctness.
# Checks structural and shell-logic issues — NOT variant-specific flag values.
#
# Checks:
#   1. YAML syntax (python3 safe_load)
#   2. PATH exported before first curl/wget in late-commands
#   3. USB fallback includes live-installer mount points (not just legacy paths)
#   4. INSTALLED counter inside if-success branch (not after fi)
#   5. lsinitramfs uses installed kernel, not uname -r (installer kernel)
#   6. Firmware BLOBS list present and non-empty
#   7. No colon-space in YAML plain scalar echo/printf strings
#   8. No shell builtins used with exec_always in compositor configs
#   9. curtin in-target used for chroot operations (not bare late-command)
#  10. Git version capture block present (diagnostic completeness)
#
# Usage:
#   ./script/validate-autoinstall.sh [--file <path>] [--verbose]
#
# Exit code: 0 = all pass, 1 = one or more checks failed

set -euo pipefail

VARIANTS_DIR="$(cd "$(dirname "$0")/../os/ubuntu/variants" && pwd)"
PASS=0
FAIL=0
WARN=0
VERBOSE=false
SINGLE_FILE=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) SINGLE_FILE="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
pass()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn()  { echo "  [WARN] $1"; WARN=$((WARN+1)); }
vlog()  { $VERBOSE && echo "         $1" || true; }

# ── File list ─────────────────────────────────────────────────────────────────
if [[ -n "$SINGLE_FILE" ]]; then
  FILES=("$SINGLE_FILE")
else
  FILES=()
  for f in "$VARIANTS_DIR"/autoinstall-*.yaml; do
    [[ "$(basename "$f")" == ._* ]] && continue
    [[ -f "$f" ]] && FILES+=("$f")
  done
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No autoinstall YAML files found in $VARIANTS_DIR" >&2
  exit 1
fi

echo "==================================================================="
echo "  Autoinstall YAML Validator"
echo "  Variants dir: $VARIANTS_DIR"
echo "  Files: ${#FILES[@]}"
echo "==================================================================="

# ── Per-file checks ───────────────────────────────────────────────────────────
for yaml_file in "${FILES[@]}"; do
  basename_file=$(basename "$yaml_file")
  echo ""
  echo "--- $basename_file ---"

  # ── Check 1: YAML syntax ──────────────────────────────────────────────────
  if python3 -c "
import sys, yaml
try:
    with open('$yaml_file', encoding='utf-8', errors='replace') as f:
        yaml.safe_load(f)
    sys.exit(0)
except yaml.YAMLError as e:
    print(f'YAML error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/tmp/yaml_err_$$; then
    pass "YAML syntax valid"
  else
    fail "YAML syntax: $(cat /tmp/yaml_err_$$)"
    rm -f /tmp/yaml_err_$$
    continue  # skip remaining checks on unparseable file
  fi
  rm -f /tmp/yaml_err_$$

  # ── Check 2: PATH export before first network download ───────────────────
  # late-commands run in minimal installer shell — PATH must be set before curl/wget
  has_network_dl=false
  grep -q 'curl -sfL\|curl -fsSL\|wget ' "$yaml_file" && has_network_dl=true
  if $has_network_dl; then
    if grep -q 'export PATH=.*sbin.*bin' "$yaml_file"; then
      path_line=$(grep -n 'export PATH=.*sbin.*bin' "$yaml_file" | head -1 | cut -d: -f1)
      dl_line=$(grep -n 'curl -sfL\|curl -fsSL\|wget ' "$yaml_file" | head -1 | cut -d: -f1)
      if [[ -n "$path_line" && -n "$dl_line" && "$path_line" -lt "$dl_line" ]]; then
        pass "PATH exported (line $path_line) before first download (line $dl_line)"
      else
        warn "PATH export exists (line $path_line) but may not precede download (line $dl_line)"
      fi
    else
      fail "No PATH export found — curl/wget may fail with 'command not found' in installer shell"
    fi
  fi

  # ── Check 3: USB fallback includes modern live-installer mount points ─────
  # Ubuntu live USB mounts at /isodevice, /run/live/medium, or /run/mnt/ubuntu-seed
  # Old scripts only checked /cdrom /media/cdrom /mnt/usb — all fail on modern installers
  if grep -q 'for usbpath in' "$yaml_file"; then
    missing_mounts=""
    for mp in /isodevice /run/live/medium /run/mnt/ubuntu-seed; do
      grep -q "$mp" "$yaml_file" || missing_mounts="$missing_mounts $mp"
    done
    if [[ -z "$missing_mounts" ]]; then
      pass "USB fallback includes modern live-installer mount points"
    else
      fail "USB fallback missing mount points:$missing_mounts (live USB won't be found)"
    fi
  fi

  # ── Check 4: INSTALLED counter inside if-success (not after fi) ──────────
  # Bug: if INSTALLED++ is after `fi`, it counts zstd failures as installs
  if grep -q 'INSTALLED=0' "$yaml_file"; then
    # Look for the pattern: fi on one line, INSTALLED++ on next
    if awk '/fi$/{getline; if (/INSTALLED=\$\(\(INSTALLED/) print}' "$yaml_file" | grep -q .; then
      fail "INSTALLED counter is after 'fi' — counts zstd failures; move inside if-success branch"
    else
      pass "INSTALLED counter is inside if-success branch"
    fi
  fi

  # ── Check 5: lsinitramfs uses installed kernel, not uname -r ─────────────
  # uname -r inside curtin in-target returns the INSTALLER kernel version,
  # not the installed target kernel — lsinitramfs then looks for the wrong initrd
  if grep -q 'lsinitramfs' "$yaml_file"; then
    if grep 'lsinitramfs' "$yaml_file" | grep -q 'uname -r'; then
      fail "lsinitramfs uses 'uname -r' — returns installer kernel, not installed kernel"
    else
      pass "lsinitramfs uses installed kernel detection"
    fi
  fi

  # ── Check 6: Firmware BLOBS list present and non-empty ───────────────────
  if grep -q 'BLOBS=' "$yaml_file"; then
    blob_line=$(grep 'BLOBS=' "$yaml_file" | head -1)
    # Count space-separated tokens after BLOBS=
    blob_tokens=$(echo "$blob_line" | sed 's/.*BLOBS="\?\([^"]*\)"\?.*/\1/' | wc -w | tr -d ' ')
    if [[ "$blob_tokens" -ge 10 ]]; then
      pass "Firmware BLOBS list present ($blob_tokens blobs)"
    elif [[ "$blob_tokens" -gt 0 ]]; then
      warn "Firmware BLOBS list seems short ($blob_tokens blobs — expected ~12 for Raphael)"
    else
      fail "Firmware BLOBS list is empty"
    fi
  fi

  # ── Check 7: No colon-space in YAML plain scalar echo/bash-c strings ────────
  # `: ` inside a single-line `- bash -c '...'` YAML list item is parsed as a
  # mapping indicator at that column — causes "mapping values not allowed here".
  # Only risky in direct list items (- curtin in-target -- bash -c '...'),
  # NOT in block scalars (- |).  Pattern: UPPERCASE_WORD: UPPERCASE_WORD
  colon_hits=$(grep -n "^\s\+- .*bash -c.*[A-Z_]\+: [A-Z_]" "$yaml_file" 2>/dev/null \
    | grep -v '#' | head -5 || true)
  if [[ -n "$colon_hits" ]]; then
    fail "Colon-space in single-line bash -c plain scalar (use KEY=VALUE, not KEY: VALUE):"
    echo "$colon_hits" | while IFS= read -r line; do warn "    $line"; done
  else
    pass "No colon-space hazard in bash -c plain scalars"
  fi

  # ── Check 8: No shell builtins used with exec_always ─────────────────────
  # sway/labwc exec_always runs executables, not shell builtins
  # export, source, alias etc. will silently fail or error
  builtin_hits=$(grep -n 'exec_always\s*\(export\|source\|alias\|cd\|set\|unset\)' "$yaml_file" || true)
  if [[ -n "$builtin_hits" ]]; then
    fail "exec_always with shell builtin (wrap in sh -c or use environment.d instead):"
    echo "$builtin_hits" | while IFS= read -r line; do vlog "    $line"; done
  else
    pass "No exec_always shell builtin hazard"
  fi

  # ── Check 9: update-initramfs/update-grub not run bare in late-commands ──────
  # These MUST run inside curtin in-target -- (chroot), not bare.
  # Bare execution affects the live installer, not /target.
  bare_initramfs=$(grep -n '^\s*- \(update-initramfs\|update-grub\)' "$yaml_file" \
    | grep -v 'curtin in-target\|in-target --\|#' || true)
  if [[ -n "$bare_initramfs" ]]; then
    fail "update-initramfs/update-grub run bare (must use 'curtin in-target --'):"
    echo "$bare_initramfs" | while IFS= read -r line; do vlog "    $line"; done
  else
    pass "update-initramfs/update-grub use curtin in-target"
  fi

  # ── Check 10: Git version capture present ────────────────────────────────
  if grep -q 'autoinstall-version.txt' "$yaml_file"; then
    pass "Git version capture present (autoinstall-version.txt)"
  else
    warn "No git version capture — install run won't record which variant/commit was used"
  fi

done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==================================================================="
printf "  Results: %d passed, %d failed, %d warnings\n" "$PASS" "$FAIL" "$WARN"
echo "==================================================================="

if [[ $FAIL -gt 0 ]]; then
  echo "  OVERALL: FAIL"
  exit 1
else
  echo "  OVERALL: PASS"
  exit 0
fi
